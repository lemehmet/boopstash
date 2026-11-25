import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// Settings ▸ Model and Generate in the workbench (ADR 0014, #269), with
/// a fake helper and a fake Keychain: no test here starts the model
/// helper, reaches a network or touches the user's Keychain or settings.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ModelEndpointFlowTests {
    /// Stands in for the model helper: records what it was handed.
    actor FakeHelper {
        var requests: [ModelServiceRequest] = []
        var models: Result<[String], ModelServiceResponse.Failure> = .success(["coder", "flash", "tiny"])
        var chat = ModelServiceResponse(status: 200, body: FakeHelper.completion("```js\n\(ScriptWorkbenchFlowTests.prefixing)\n```"))
        var hangs = false

        static func completion(_ content: String?, finish: String = "stop") -> Data {
            var message: [String: Any] = ["role": "assistant"]
            if let content { message["content"] = content }
            return try! JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": finish]]])
        }

        func set(models: Result<[String], ModelServiceResponse.Failure>) { self.models = models }
        func set(chat: ModelServiceResponse) { self.chat = chat }
        func setHangs() { hangs = true }

        func send(_ request: ModelServiceRequest) async -> ModelServiceResponse {
            requests.append(request)
            switch request.call {
            case .models:
                switch models {
                case .success(let names):
                    let data = try! JSONSerialization.data(withJSONObject: ["object": "list", "data": names.map { ["id": $0] }])
                    return ModelServiceResponse(status: 200, body: data)
                case .failure(let failure):
                    return ModelServiceResponse(failure: failure)
                }
            case .chat:
                if hangs {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    return ModelServiceResponse(failure: .cancelled)
                }
                return chat
            }
        }
    }

    /// A Keychain that is a dictionary.
    final class FakeKeys: ModelKeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var keys: [String: String] = [:]
        private var locked = false

        struct Locked: Error {}

        var all: [String: String] { lock.withLock { keys } }
        func lockUp() { lock.withLock { locked = true } }

        func read(account: String) throws -> String? {
            try lock.withLock {
                if locked { throw Locked() }
                return keys[account]
            }
        }

        func write(_ key: String, account: String) throws {
            try lock.withLock {
                if locked { throw Locked() }
                keys[account] = key.isEmpty ? nil : key
            }
        }
    }

    let suite = "model-endpoint-tests-\(UUID().uuidString)"
    let helper = FakeHelper()
    let keys = FakeKeys()
    let flows = ScriptWorkbenchFlowTests()

    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }

    func store() -> ModelEndpointStore {
        ModelEndpointStore(defaults: defaults, keys: keys, transport: { [helper] in await helper.send($0) })
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// A store set up for a model on the local network.
    func configured(model: String = "coder") -> ModelEndpointStore {
        let store = store()
        store.setBaseURL("http://studio.local:8080")
        store.setModel(model)
        return store
    }

    func body(_ request: ModelServiceRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Settings

    @Test func theFeatureIsOffByDefaultAndAsksNothing() async {
        defer { cleanUp() }
        let store = store()
        #expect(store.settings == ModelEndpointSettings() && store.state == .off)
        #expect(store.indicator == nil && store.modelOptions == nil && store.listNote == nil && !store.hasKey)
        #expect(await store.generator.availability() == .notConfigured)
        #expect(store.refreshModels() == nil && store.test() == nil, "with no endpoint there is nothing to ask")
        store.refreshKeyState()
        #expect(await helper.requests.isEmpty)
    }

    @Test func theSettingsRoundTripAndTheKeyIsOnlyInTheKeychain() async throws {
        defer { cleanUp() }
        let first = configured()
        first.setKey(" sk-test-1 ")
        first.enter("0.7", in: .temperature)
        #expect(first.setExtraFields(#"{"chat_template_kwargs":{"enable_thinking":false}}"#))
        #expect(first.hasKey && first.keyProblem == nil)
        #expect(keys.all == ["http://studio.local:8080": "sk-test-1"])

        let second = store()
        #expect(second.settings == first.settings)
        #expect(second.settings.baseURL == "http://studio.local:8080" && second.settings.model == "coder")
        #expect(second.settings.generation.temperature == 0.7)
        second.refreshKeyState()
        #expect(second.hasKey)
        #expect(try second.key() == "sk-test-1")
        // Nothing the app saves outside the Keychain holds the key.
        let saved = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("modelEndpoint") }
        for value in saved.values {
            let text = (value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
            #expect(!text.contains("sk-test-1"))
        }
        #expect(!saved.isEmpty)
        #expect(await helper.requests.isEmpty, "opening and changing the settings asks the service nothing")

        second.setKey("")
        #expect(!second.hasKey && keys.all.isEmpty)
    }

    @Test func aKeyBelongsToTheEndpointItWasEnteredFor() async throws {
        defer { cleanUp() }
        let store = store()
        store.setKey("sk-test-1")
        #expect(store.keyProblem == "Enter the base URL first: a key is kept for the endpoint it belongs to." && keys.all.isEmpty)
        store.setBaseURL("http://studio.local:8080")
        store.setKey("sk-test-1")
        #expect(store.hasKey)
        store.setBaseURL("https://models.example")
        #expect(!store.hasKey, "another host has no key until one is entered for it")
        #expect(try store.key() == nil)
        store.setModel("m")
        await store.test()?.value
        #expect(await helper.requests.last?.apiKey == nil, "the first host's key is not sent to the second")
        store.setBaseURL("http://studio.local:8080")
        #expect(store.hasKey)

        keys.lockUp()
        store.setKey("sk-test-2")
        #expect(store.keyProblem?.hasPrefix("The key could not be saved in the Keychain.") == true)
    }

    @Test func theModelListComesFromTheServiceOnTheUsersAction() async throws {
        defer { cleanUp() }
        let store = store()
        #expect(store.setBaseURL(" http://studio.local:8080 "))
        #expect(!store.setBaseURL("http://studio.local:8080"), "the same address is not a change")
        #expect(store.modelOptions == nil)
        #expect(store.listNote == "Press Refresh to fetch the service's model list, or type the model's name.")
        store.setKey("sk-test-1")
        await store.refreshModels()?.value
        #expect(store.modelOptions?.map(\.title) == ["coder", "flash", "tiny"] && store.listNote == nil && !store.isListing)
        #expect(await helper.requests == [ModelServiceRequest(call: .models, baseURL: "http://studio.local:8080", apiKey: "sk-test-1",
                                                               body: nil, timeLimit: 15)], "the key and nothing else")
        store.setModel("flash")

        // Settings opened again: the list is shown without a request.
        let reopened = self.store()
        reopened.refreshKeyState()
        #expect(reopened.modelOptions?.map(\.title) == ["coder", "flash", "tiny"] && reopened.settings.model == "flash")
        #expect(await helper.requests.count == 1)

        // The service stopped listing the chosen model: it stays, marked.
        await helper.set(models: .success(["coder", "tiny"]))
        await reopened.refreshModels()?.value
        #expect(reopened.modelOptions?.map(\.title) == ["flash (not offered by the service)", "coder", "tiny"])
        #expect(reopened.settings.model == "flash")

        // The service is down: a name can be typed, and the pane says why.
        await helper.set(models: .failure(.unreachable("Could not connect to the server.")))
        await reopened.refreshModels()?.value
        #expect(reopened.modelOptions == nil)
        #expect(reopened.listNote == "The model list could not be fetched, so type the model's name. The model at studio.local:8080 could not be reached: Could not connect to the server.")
        reopened.setModel(" typed-model ")
        #expect(reopened.settings.model == "typed-model")
        #expect(self.store().modelOptions == nil, "a list that could not be fetched is not remembered")

        // A service with no models takes a typed name too.
        await helper.set(models: .success([]))
        await reopened.refreshModels()?.value
        #expect(reopened.modelOptions == nil && reopened.listNote == "The service lists no models, so type the model's name.")

        // Another address has no list until it is fetched.
        await helper.set(models: .success(["other"]))
        reopened.setBaseURL("http://localhost:1234")
        #expect(reopened.modelOptions == nil && self.store().modelOptions == nil)
    }

    @Test func aBaseURLThatIsNotAnAddressSaysWhyAndIsNotAsked() async {
        defer { cleanUp() }
        let store = store()
        store.setBaseURL("http://models.example")
        #expect(store.addressProblem == ModelEndpointAddress.Problem.plainHTTP(host: "models.example").message)
        #expect(store.indicator == nil && store.refreshModels() == nil)
        store.setModel("m")
        #expect(store.test() == nil && store.testResult?.passed == false)
        #expect(await helper.requests.isEmpty)
        store.setBaseURL("https://models.example")
        #expect(store.addressProblem == nil && store.indicator?.isStrong == true)
        #expect(store.indicator?.details.contains("models.example, which is not this Mac or your local network") == true)
        store.setBaseURL("http://localhost:8080")
        #expect(store.indicator?.isStrong == false && store.indicator?.symbol == ModelEndpointIndicator.mark)
    }

    @Test func generationSettingsAreClampedRefusedAndReset() async throws {
        defer { cleanUp() }
        let store = configured()
        store.enter("9", in: .temperature)
        #expect(store.settings.generation.temperature == 2 && store.notes[.temperature] == "Must be between 0.0 and 2.0; set to 2.0.")
        store.enter("1.5", in: .temperature)
        #expect(store.notes[.temperature] == nil && store.settings.generation.temperature == 1.5)
        store.enter("4096", in: .contextLength)
        #expect(store.settings.generation.contextLength == 4_096 && store.settings.generation.maxReplyTokens == 2_048)
        store.enter("2500", in: .contextLength)
        #expect(store.settings.generation.maxReplyTokens == 2_500 - 1_024, "the reply limit follows a smaller context")
        #expect(store.notes[.maxReplyTokens]?.hasPrefix("The reply must leave") == true)

        #expect(!store.setExtraFields("enable_thinking: false"))
        #expect(store.extraFieldsProblem?.hasPrefix("This is not valid JSON.") == true)
        #expect(store.settings.generation.extraFields.isEmpty, "refused text is not kept")
        #expect(store.setExtraFields(ModelDialect.all[0].fields), "choosing a dialect fills the field")
        #expect(store.extraFieldsProblem == nil && store.settings.generation.extraFields == #"{"chat_template_kwargs":{"enable_thinking":false}}"#)
        #expect(!store.setExtraFields("[1]") && store.settings.generation.extraFields == ModelDialect.all[0].fields)

        // The next request carries the changed settings.
        store.enter("0.9", in: .topP)
        store.enter("60", in: .timeLimit)
        await store.test()?.value
        let request = try #require(await helper.requests.last)
        let sent = try body(request)
        #expect(sent["temperature"] as? Double == 1.5 && sent["top_p"] as? Double == 0.9 && sent["max_tokens"] as? Int == 1_476)
        #expect((sent["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
        #expect(request.timeLimit == 60)

        store.resetGeneration()
        #expect(store.settings.generation == .defaults && store.notes.isEmpty && store.extraFieldsProblem == nil)
        #expect(self.store().settings.generation == .defaults)
        await store.test()?.value
        let plain = try body(try #require(await helper.requests.last))
        #expect(Set(plain.keys) == ["model", "messages", "temperature", "top_p", "max_tokens", "stream"])
        #expect(plain["temperature"] as? Double == 0.2 && plain["top_p"] as? Double == 1.0 && plain["max_tokens"] as? Int == 2_048)
    }

    @Test func testSendsNoneOfTheUsersTextAndSaysWhatCameBack() async throws {
        defer { cleanUp() }
        let store = configured()
        await store.test()?.value
        #expect(store.testResult == ModelEndpointStore.TestResult(passed: true, text: "The model answered with a script.") && !store.isTesting)
        let request = try #require(await helper.requests.last)
        #expect(request.call == .chat && request.baseURL == "http://studio.local:8080")
        let messages = try #require(try body(request)["messages"] as? [[String: String]])
        #expect(messages.map { $0["content"] } == [ModelScriptPrompt.instructions(wholeText: true), "Task: trim every line\n\nThe text:\n  alpha  \n beta"])

        await helper.set(chat: ModelServiceResponse(status: 200, body: FakeHelper.completion(nil, finish: "length")))
        await store.test()?.value
        #expect(store.testResult == ModelEndpointStore.TestResult(passed: false, text: ScriptGenerationFailure.cutOff.message ?? ""))
        await helper.set(chat: ModelServiceResponse(status: 400, body: Data(#"{"error":{"message":"unknown field"}}"#.utf8)))
        await store.test()?.value
        #expect(store.testResult?.text == "studio.local:8080 answered with an error (HTTP 400): unknown field")
    }

    @Test func aProblemReportHoldsNothingOfTheEndpoint() async throws {
        defer { cleanUp() }
        let store = configured(model: "secret-model-name")
        store.setKey("sk-test-1")
        #expect(store.setExtraFields(#"{"private_field":"private-value"}"#))
        await store.test()?.value
        let model = AppModel(store: try .inMemory())
        model.modelEndpoint = store
        // The report reads the same settings the endpoint was saved in.
        #expect(defaults.data(forKey: ModelEndpointStore.settingsKey) != nil)
        let report = try #require(model.createProblemReport(
            environment: model.problemReportEnvironment(defaults: defaults),
            note: model.problemReportNote(editor: nil, defaults: defaults),
            list: model.problemReportList(), logLines: try LiveDiagnostics.recentLog(since: Date().addingTimeInterval(-600)), screenshot: nil))
        for hidden in ["sk-test-1", "studio.local", "secret-model-name", "private_field", "private-value", "trim every line"] {
            #expect(!report.body.contains(hidden) && !report.title.contains(hidden), "\(hidden)")
        }
        #expect(report.body.contains("## Environment"))
    }

    @Test func aTestIsOfTheSettingsShownAndGoesWhenTheyChange() async throws {
        defer { cleanUp() }
        let store = configured()
        await store.test()?.value
        #expect(store.testResult?.passed == true)
        // Each change takes the verdict away: it was on other settings.
        store.enter("0.9", in: .temperature)
        #expect(store.testResult == nil)
        await store.test()?.value
        store.enter("0.9", in: .temperature)
        #expect(store.testResult?.passed == true, "typing the same value changes nothing")
        #expect(store.setExtraFields(#"{"seed":1}"#) && store.testResult == nil)
        await store.test()?.value
        store.resetGeneration()
        #expect(store.testResult == nil)
        await store.test()?.value
        store.setModel("flash")
        #expect(store.testResult == nil)

        // A test in flight is cancelled by a change, and never reports.
        await helper.setHangs()
        let running = try #require(store.test())
        #expect(store.isTesting)
        let deadline = ContinuousClock.now + .seconds(10)
        while await helper.requests.last?.call != .chat || store.testResult != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.setModel("tiny")
        #expect(!store.isTesting && store.testResult == nil, "and another test can start at once")
        await running.value
        #expect(store.testResult == nil && !store.isTesting)
    }

    // MARK: The workbench

    @Test func withNoEndpointTheWorkbenchHasNoPromptAndTheHelperIsNeverAsked() async {
        defer { cleanUp() }
        let (window, view) = flows.host(ScriptWorkbenchFlowTests.numbers)
        let store = store()
        defer { withExtendedLifetime(store) {} }
        let session = await flows.workbench(on: view, generator: store.generator)
        #expect(session.destination == nil && session.unavailableReason == nil, "no prompt field, no Generate")
        #expect(session.sampleToSend == nil)
        session.instruction = "make links"
        session.generate()
        #expect(session.generatingTask == nil && !session.isGenerating)
        #expect(await helper.requests.isEmpty)
        flows.close(window, view)
    }

    @Test func generateSendsTheInstructionAndTheShownSampleAndTheDraftDoesNotRun() async throws {
        defer { cleanUp() }
        let (window, view) = flows.host(ScriptWorkbenchFlowTests.numbers)
        let store = configured()
        defer { withExtendedLifetime(store) {} }
        let session = await flows.workbench(on: view, script: ScriptSkeleton.blank.source, generator: store.generator)
        let destination = try #require(session.destination)
        #expect(destination.host == "studio.local:8080" && destination.locality == .localNetwork)
        #expect(destination.indicator?.symbol == ModelEndpointIndicator.mark && destination.indicator?.details.contains("studio.local:8080") == true)
        session.instruction = " turn each number into a tracker link "
        let shown = try #require(session.sampleToSend)
        #expect(shown == ScriptSample(text: ScriptWorkbenchFlowTests.numbers, isWholeText: true, totalLines: 3))
        session.generate()
        #expect(session.isGenerating)
        await session.generatingTask?.value
        #expect(session.script == ScriptWorkbenchFlowTests.prefixing, "the reply's script, without its fence")
        #expect(session.result == nil && view.string == ScriptWorkbenchFlowTests.numbers, "in the editor, not run")
        #expect(session.notice?.isError == false)

        #expect(await helper.requests.count == 1)
        let request = try #require(await helper.requests.first)
        let messages = try #require(try body(request)["messages"] as? [[String: String]])
        #expect(messages.count == 2 && messages[0]["content"] == ModelScriptPrompt.instructions(wholeText: true))
        #expect(messages[1]["content"] == ModelScriptPrompt.request(instruction: "turn each number into a tracker link", sample: shown))
        flows.close(window, view)
    }

    @Test func onlyTheSelectionAndTheLinesMarkedAsExamplesGoWithIt() async throws {
        defer { cleanUp() }
        let note = "title: registers\nREG_A 1\nREG_B 2\nREG_C 3\nfooter"
        let (window, view) = flows.host(note)
        view.setSelectedRange((note as NSString).range(of: "REG_A 1\nREG_B 2\nREG_C 3"))
        // The app keeps the store; the generator only reads it.
        let store = configured()
        defer { withExtendedLifetime(store) {} }
        let session = await flows.workbench(on: view, generator: store.generator)
        #expect(session.generationTarget == "REG_A 1\nREG_B 2\nREG_C 3")
        session.markExample(line: 3)
        session.markExample(line: 9)
        #expect(session.exampleProblem == "The text has 3 lines; there is no line 9.")
        session.markExample(line: 1)
        #expect(session.exampleProblem == nil && session.examples.map(\.text) == ["REG_A 1", "REG_C 3"])
        session.setExpected("#define REG_A (1)", forExampleAt: 1)
        session.markExample(line: 2)
        session.unmarkExample(line: 2)
        #expect(session.examples == [ScriptExample(line: 1, text: "REG_A 1", expected: "#define REG_A (1)"), ScriptExample(line: 3, text: "REG_C 3")])
        session.instruction = "make defines"
        session.generate()
        await session.generatingTask?.value
        let request = try #require(await helper.requests.first)
        let content = try #require((try body(request)["messages"] as? [[String: String]])?.last?["content"])
        #expect(content == ModelScriptPrompt.request(instruction: "make defines", examples: session.examples,
                                                     sample: ScriptSample(text: "REG_A 1\nREG_B 2\nREG_C 3", isWholeText: true, totalLines: 3)))
        #expect(content.contains("This line:\nREG_A 1\nmust become exactly:\n#define REG_A (1)"))
        let sent = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(!sent.contains("title: registers") && !sent.contains("footer"), "nothing else of the note")
        flows.close(window, view)
    }

    @Test func whatIsSentIsWhatWasShownEvenIfTheNoteChangesUnderTheSheet() async throws {
        defer { cleanUp() }
        let store = configured()
        defer { withExtendedLifetime(store) {} }
        let (window, view) = flows.host("REG_A 1\nREG_B 2")
        let session = await flows.workbench(on: view, generator: store.generator)
        session.instruction = "make defines"
        session.markExample(line: 2)
        let shown = try #require(session.sampleToSend)
        #expect(shown.text == "REG_A 1\nREG_B 2")
        // The note changes under the open workbench, as a sync can change it.
        view.load("PRIVATE 9\nNEVER SHOWN 8\nMORE 7", syntax: .plain, sameNote: true)
        #expect(session.sampleToSend == shown, "the workbench still shows what it showed")
        session.generate()
        await session.generatingTask?.value
        let request = try #require(await helper.requests.first)
        let content = try #require((try body(request)["messages"] as? [[String: String]])?.last?["content"])
        #expect(content == ModelScriptPrompt.request(instruction: "make defines", examples: [ScriptExample(line: 2, text: "REG_B 2")], sample: shown))
        let sent = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(!sent.contains("PRIVATE") && !sent.contains("NEVER SHOWN") && !sent.contains("MORE 7"), "nothing that was not shown")
        // Sizing the sample again does not read the note either.
        session.instruction = "make defines again"
        #expect(session.sampleToSend == shown && session.examples.map(\.text) == ["REG_B 2"])
        session.markExample(line: 1)
        #expect(session.examples.map(\.text) == ["REG_A 1", "REG_B 2"], "examples are lines of the text that was shown")
        // Check Again reads the note, and shows what it read: the marked
        // lines are no longer in it, so they go.
        session.checkAgain()
        await session.availabilityCheck?.value
        #expect(session.sampleToSend?.text == "PRIVATE 9\nNEVER SHOWN 8\nMORE 7" && session.examples.isEmpty)
        flows.close(window, view)
    }

    @Test func anEndpointChangedInSettingsUnderTheSheetGetsNothingUntilItIsShown() async throws {
        defer { cleanUp() }
        let store = configured()
        defer { withExtendedLifetime(store) {} }
        store.setKey("sk-test-first")
        let (window, view) = flows.host(ScriptWorkbenchFlowTests.numbers)
        let session = await flows.workbench(on: view, generator: store.generator)
        #expect(session.destination?.host == "studio.local:8080")
        // Settings now name another host; the workbench still shows the first.
        store.setBaseURL("https://models.example")
        session.instruction = "links"
        session.generate()
        await session.generatingTask?.value
        #expect(await helper.requests.isEmpty, "nothing goes to a host the mark did not name")
        #expect(session.destination == nil && session.unavailableReason == ModelEndpointGenerator.settingsChanged)
        #expect(session.sampleToSend == nil)
        session.checkAgain()
        await session.availabilityCheck?.value
        #expect(session.destination?.host == "models.example" && session.destination?.indicator?.isStrong == true)
        session.generate()
        await session.generatingTask?.value
        let request = try #require(await helper.requests.first)
        #expect(request.baseURL == "https://models.example" && request.apiKey == nil, "and the first host's key does not go with it")
        flows.close(window, view)
    }

    @Test func anEndpointThatIsSetUpButUnusableShowsGenerateDisabledWithTheReason() async throws {
        defer { cleanUp() }
        let store = store()
        defer { withExtendedLifetime(store) {} }
        store.setBaseURL("http://studio.local:8080")
        let (window, view) = flows.host(ScriptWorkbenchFlowTests.numbers)
        let session = await flows.workbench(on: view, generator: store.generator)
        #expect(session.destination == nil && session.unavailableReason == "No model is chosen in Settings ▸ Model.")
        session.instruction = "links"
        session.generate()
        #expect(session.generatingTask == nil)
        // Fixed in Settings; the workbench asks again without sending anything.
        store.setModel("coder")
        session.checkAgain()
        await session.availabilityCheck?.value
        #expect(session.destination != nil && session.unavailableReason == nil)
        #expect(await helper.requests.isEmpty)

        // The model cannot be reached: said, disabled, and usable by hand.
        await helper.set(chat: ModelServiceResponse(failure: .unreachable("Could not connect to the server.")))
        session.generate()
        await session.generatingTask?.value
        let reason = "The model at studio.local:8080 could not be reached: Could not connect to the server."
        #expect(session.notice == ScriptWorkbenchSession.Notice(isError: true, text: reason))
        #expect(session.destination == nil && session.unavailableReason == reason)
        #expect(session.script == ScriptWorkbenchFlowTests.prefixing)
        await session.run()
        #expect(session.result != nil, "a hand-written script still runs")
        session.checkAgain()
        await session.availabilityCheck?.value
        #expect(session.destination != nil)
        flows.close(window, view)
    }

    @Test func theWorkbenchSaysWhichWayARequestFailed() async throws {
        defer { cleanUp() }
        let (window, view) = flows.host(ScriptWorkbenchFlowTests.numbers)
        // The app keeps the store; the generator only reads it.
        let store = configured()
        defer { withExtendedLifetime(store) {} }
        let session = await flows.workbench(on: view, generator: store.generator)
        session.instruction = "links"
        func notice(after response: ModelServiceResponse) async -> String? {
            await helper.set(chat: response)
            session.generate()
            await session.generatingTask?.value
            return session.notice?.text
        }
        #expect(await notice(after: .init(status: 200, body: FakeHelper.completion("", finish: "length")))
            == "The model ran out of reply tokens before it answered. Switch its reasoning off (Settings ▸ Model ▸ extra request fields) or raise the maximum reply.")
        #expect(await notice(after: .init(status: 200, body: FakeHelper.completion("I would rather not."))) == "The reply held no script with a main function.")
        #expect(await notice(after: .init(failure: .timedOut))?.hasPrefix("The model at studio.local:8080 did not answer within 180 seconds.") == true)
        #expect(await notice(after: .init(status: 500, body: Data(#"{"error":"out of memory"}"#.utf8)))
            == "studio.local:8080 answered with an error (HTTP 500): out of memory")
        #expect(session.destination != nil, "these leave Generate as it was")
        #expect(session.script == ScriptWorkbenchFlowTests.prefixing && view.string == ScriptWorkbenchFlowTests.numbers)
        flows.close(window, view)
    }

    @Test func aRequestToTheModelCanBeCancelled() async throws {
        defer { cleanUp() }
        await helper.setHangs()
        let (window, view) = flows.host(ScriptWorkbenchFlowTests.numbers)
        // The app keeps the store; the generator only reads it.
        let store = configured()
        defer { withExtendedLifetime(store) {} }
        let session = await flows.workbench(on: view, generator: store.generator)
        session.instruction = "links"
        session.generate()
        let task = try #require(session.generatingTask)
        let deadline = ContinuousClock.now + .seconds(10)
        while await helper.requests.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        session.cancelGenerating()
        await task.value
        #expect(!session.isGenerating && session.notice == nil && session.script == ScriptWorkbenchFlowTests.prefixing)
        flows.close(window, view)
    }
}
