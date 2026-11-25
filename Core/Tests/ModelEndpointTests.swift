import Foundation
import Testing
@testable import BoopstashCore

/// A model the user runs themselves (ADR 0014, #269): the settings and
/// their ranges, the extra request fields, where a host is, the mark that
/// says so, the request a generator makes and how its reply is read. No
/// test here reaches a network: the helper is a closure.
struct ModelEndpointTests {
    // MARK: Settings

    @Test func theDefaultsAreTheOnesTheMeasurementsFavour() {
        let defaults = ModelGenerationSettings.defaults
        #expect(defaults.contextLength == 32_768 && defaults.maxReplyTokens == 2_048)
        #expect(defaults.temperature == 0.2 && defaults.topP == 1.0 && defaults.timeLimit == 180)
        #expect(defaults.extraFields.isEmpty)
        #expect(defaults.clamped().notes.isEmpty, "the defaults are in range")
        #expect(ModelEndpointSettings().generation == defaults)
        #expect(ModelEndpointSettings().state == .off, "empty by default: the feature is off")
    }

    @Test func aValueOutOfRangeIsClampedAndSaysSo() {
        var settings = ModelGenerationSettings.defaults
        settings.temperature = 9
        settings.topP = -1
        settings.contextLength = 10
        settings.maxReplyTokens = 1_000_000
        settings.timeLimit = 0
        let (settled, notes) = settings.clamped()
        #expect(settled.temperature == 2 && settled.topP == 0 && settled.contextLength == 2_048 && settled.timeLimit == 5)
        #expect(settled.maxReplyTokens == 1_024, "the reply leaves the reserve of the context free")
        #expect(notes[.temperature] == "Must be between 0.0 and 2.0; set to 2.0.")
        #expect(notes[.contextLength] == "Must be between 2048 and 2000000; set to 2048.")
        #expect(notes[.maxReplyTokens] == "The reply must leave 1024 tokens of the context free; set to 1024.")
        #expect(Set(notes.keys) == Set(ModelGenerationSettings.Field.allCases))
        settings = .defaults
        settings.temperature = .nan
        #expect(settings.clamped().settings.temperature == 0.2, "not a number: the default")
    }

    @Test func typingAValueIntoAFieldKeepsItInRange() {
        let defaults = ModelGenerationSettings.defaults
        var entered = defaults.entering("0.7", in: .temperature)
        #expect(entered.settings.temperature == 0.7 && entered.notes.isEmpty)
        entered = defaults.entering("0,5", in: .topP)
        #expect(entered.settings.topP == 0.5 && entered.notes.isEmpty, "a decimal comma reads as a point")
        entered = defaults.entering("5", in: .temperature)
        #expect(entered.settings.temperature == 2 && entered.notes[.temperature] == "Must be between 0.0 and 2.0; set to 2.0.")
        entered = defaults.entering("warm", in: .temperature)
        #expect(entered.settings.temperature == 0.2)
        #expect(entered.notes[.temperature] == "\"warm\" is not a number; the default, 0.2, is back.")
        entered = defaults.entering("8192.6", in: .maxReplyTokens)
        #expect(entered.settings.maxReplyTokens == 8_193 && entered.notes.isEmpty)
        entered = defaults.entering("60000", in: .maxReplyTokens)
        #expect(entered.settings.maxReplyTokens == 32_768 - 1_024 && entered.notes[.maxReplyTokens]?.hasPrefix("The reply must leave") == true)
        entered = defaults.entering("1e999", in: .contextLength)
        #expect(entered.settings.contextLength == defaults.contextLength, "infinity is not a number to keep")
        entered = defaults.entering("2500", in: .contextLength)
        #expect(entered.settings.maxReplyTokens == 1_476 && entered.notes[.maxReplyTokens]?.hasPrefix("The reply must leave") == true)
        #expect(entered.notes[.contextLength] == nil, "the reply limit follows a smaller context, and says so")
        #expect(defaults.text(.contextLength) == "32768" && defaults.text(.temperature) == "0.2" && defaults.text(.topP) == "1.0")
        #expect(defaults.text(.timeLimit) == "180")
        for field in ModelGenerationSettings.Field.allCases { #expect(!field.label.isEmpty) }
    }

    @Test func settingsSurviveBeingSavedAndOldSavesReadWithDefaults() throws {
        var settings = ModelEndpointSettings(baseURL: "http://localhost:8080", model: "coder")
        settings.generation.temperature = 0.7
        settings.generation.extraFields = #"{"reasoning_effort":"none"}"#
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(ModelEndpointSettings.self, from: data) == settings)
        let old = try JSONDecoder().decode(ModelEndpointSettings.self, from: Data(#"{"baseURL":"http://localhost","generation":{"temperature":1}}"#.utf8))
        #expect(old.model.isEmpty && old.generation.temperature == 1 && old.generation.maxReplyTokens == 2_048)
        #expect(!String(decoding: data, as: UTF8.self).lowercased().contains("key"), "the settings hold no API key")
    }

    @Test func theStateSaysWhatStopsARequest() {
        #expect(ModelEndpointSettings(baseURL: "  ").state == .off)
        #expect(ModelEndpointSettings(baseURL: "localhost:8080", model: "m").state == .incomplete("The base URL must start with http:// or https://."))
        #expect(ModelEndpointSettings(baseURL: "http://localhost:8080").state == .incomplete("No model is chosen in Settings ▸ Model."))
        var settings = ModelEndpointSettings(baseURL: "http://localhost:8080", model: "m")
        guard case .ready(let address) = settings.state else {
            Issue.record("a URL and a model are ready")
            return
        }
        #expect(address.host == "localhost:8080" && address.locality == .thisMac)
        settings.generation.extraFields = "[1]"
        guard case .incomplete(let reason) = settings.state else {
            Issue.record("extra fields that are not an object stop a request")
            return
        }
        #expect(reason.hasPrefix("The extra request fields in Settings ▸ Model cannot be used: This is JSON but not an object."))
    }

    // MARK: Extra request fields and their help

    @Test func extraRequestFieldsMustBeAJSONObject() throws {
        #expect(try ModelExtraFields.parse("").get().isEmpty)
        #expect(try ModelExtraFields.parse(" \n").get().isEmpty)
        let object = try ModelExtraFields.parse(#" {"chat_template_kwargs":{"enable_thinking":false}} "#).get()
        #expect((object["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
        #expect(ModelExtraFields.problem(in: #"{"a":1}"#) == nil)
        #expect(ModelExtraFields.problem(in: "{oops")?.hasPrefix("This is not valid JSON.") == true)
        for notAnObject in ["[1,2]", "\"text\"", "3", "true", "null"] {
            #expect(ModelExtraFields.problem(in: notAnObject)?.hasPrefix("This is JSON but not an object.") == true, "\(notAnObject)")
        }
        #expect(ModelExtraFields.problem(in: #"{"messages":[]}"#) == "\"messages\" is set by BoopStash, from the settings above, and cannot be replaced here.")
        // What the interface shows as sent cannot be changed from here.
        for taken in ["model", "messages", "stream", "temperature", "top_p", "max_tokens"] {
            #expect(ModelExtraFields.problem(in: "{\"seed\":1,\"\(taken)\":1}")?.hasPrefix("\"\(taken)\" is set by BoopStash") == true, "\(taken)")
        }
        #expect(ModelExtraFields.problem(in: #"{"max_completion_tokens":1,"Model":"x"}"#) == nil, "other names are the server's business")
    }

    @Test func everyDialectExampleIsAValidJSONObjectAndIsInTheHelp() throws {
        #expect(ModelDialect.all.count == 3)
        #expect(ModelDialect.all[0].fields == #"{"chat_template_kwargs":{"enable_thinking":false}}"#)
        for dialect in ModelDialect.all {
            #expect(ModelExtraFields.problem(in: dialect.fields) == nil, "\(dialect.name)")
            #expect(try !ModelExtraFields.parse(dialect.fields).get().isEmpty)
            #expect(!dialect.note.isEmpty)
            #expect(ModelDialect.help.contains(dialect.name) && ModelDialect.help.contains(dialect.fields) && ModelDialect.help.contains(dialect.note))
        }
        #expect(Set(ModelDialect.all.map(\.id)).count == ModelDialect.all.count)
        #expect(ModelDialect.mark.unicodeScalars.count == 1, "a Unicode symbol, not an image")
    }

    // MARK: Where a host is

    @Test(arguments: [
        ("localhost", ModelHostLocality.thisMac), ("LOCALHOST", .thisMac), ("localhost.", .thisMac),
        ("127.0.0.1", .thisMac), ("127.8.9.10", .thisMac), ("::1", .thisMac), ("[::1]", .thisMac),
        ("::ffff:127.0.0.1", .thisMac),
        ("10.0.0.5", .localNetwork), ("172.16.0.1", .localNetwork), ("172.31.255.255", .localNetwork),
        ("192.168.1.20", .localNetwork), ("169.254.3.4", .localNetwork),
        ("studio.local", .localNetwork), ("Studio.Local.", .localNetwork), ("studio", .localNetwork), ("my-mac", .localNetwork),
        ("fe80::1", .localNetwork), ("fe80::1%en0", .localNetwork), ("[fd12:3456::7]", .localNetwork), ("fc00::1", .localNetwork),
        ("::ffff:192.168.1.2", .localNetwork),
        ("example.com", .elsewhere), ("models.example", .elsewhere), ("local.example.com", .elsewhere),
        ("a.localhost", .elsewhere), ("localhost.example.com", .elsewhere),
        ("8.8.8.8", .elsewhere), ("172.15.0.1", .elsewhere), ("172.32.0.1", .elsewhere), ("192.169.0.1", .elsewhere),
        ("100.64.0.1", .elsewhere), ("0.0.0.0", .elsewhere), ("2001:db8::1", .elsewhere), ("::", .elsewhere),
        ("::ffff:8.8.8.8", .elsewhere), ("fe80::zz", .elsewhere),
        // Addresses in other spellings reach whatever the resolver reads.
        ("2130706433", .elsewhere), ("0x7f000001", .elsewhere), ("0x7f.1", .elsewhere), ("127.1", .elsewhere),
        ("010.0.0.1", .elsewhere), ("192.168.1", .elsewhere), ("1.2.3.4.5", .elsewhere), ("256.1.1.1", .elsewhere),
        ("", .elsewhere), (".", .elsewhere), ("a..b", .elsewhere), (".local", .elsewhere),
    ])
    func aHostIsThisMacTheLocalNetworkOrElsewhere(host: String, expected: ModelHostLocality) {
        #expect(ModelHostLocality.of(host: host) == expected, "\(host)")
    }

    @Test func theBaseURLIsCheckedAndPlainHTTPIsForLocalAddressesOnly() throws {
        let local = try ModelEndpointAddress.parse(" http://localhost:8080/ ").get()
        #expect(local.host == "localhost:8080" && local.locality == .thisMac)
        #expect(local.chatURL.absoluteString == "http://localhost:8080/v1/chat/completions")
        #expect(local.modelsURL.absoluteString == "http://localhost:8080/v1/models")
        let versioned = try ModelEndpointAddress.parse("https://models.example/api/v1").get()
        #expect(versioned.host == "models.example" && versioned.locality == .elsewhere)
        #expect(versioned.chatURL.absoluteString == "https://models.example/api/v1/chat/completions")
        #expect(versioned.modelsURL.absoluteString == "https://models.example/api/v1/models")
        #expect(try ModelEndpointAddress.parse("http://192.168.1.20:11434").get().locality == .localNetwork)
        #expect(try ModelEndpointAddress.parse("http://[::1]:8080").get().locality == .thisMac)
        #expect(try ModelEndpointAddress.parse("HTTPS://Example.COM").get().locality == .elsewhere)

        #expect(ModelEndpointAddress.parse("http://models.example") == .failure(.plainHTTP(host: "models.example")))
        #expect(ModelEndpointAddress.parse("http://8.8.8.8:80") == .failure(.plainHTTP(host: "8.8.8.8:80")))
        #expect(ModelEndpointAddress.parse("http://2130706433") == .failure(.plainHTTP(host: "2130706433")))
        #expect(ModelEndpointAddress.parse("ftp://localhost") == .failure(.scheme))
        #expect(ModelEndpointAddress.parse("localhost:8080") == .failure(.scheme))
        #expect(ModelEndpointAddress.parse("not a url") == .failure(.notAURL))
        #expect(ModelEndpointAddress.parse("http://") == .failure(.noHost))
        #expect(ModelEndpointAddress.parse("https://user:secret@models.example") == .failure(.credentials))
        #expect(ModelEndpointAddress.parse("https://user@models.example") == .failure(.credentials))
        #expect(ModelEndpointAddress.parse("https://models.example/v1?key=secret") == .failure(.query))
        #expect(ModelEndpointAddress.parse("https://models.example/#x") == .failure(.query))
        for problem in [ModelEndpointAddress.Problem.notAURL, .scheme, .noHost, .credentials, .query, .plainHTTP(host: "h")] {
            #expect(!problem.message.isEmpty)
        }
        #expect(ModelEndpointAddress.Problem.plainHTTP(host: "models.example").message.contains("https://"))
    }

    // MARK: The mark

    @Test func theMarkSaysWhatIsSentAndWhere() {
        let here = ModelEndpointIndicator(host: "localhost:8080", locality: .thisMac, place: .workbench)
        #expect(here.symbol == "△" && !here.isStrong)
        #expect(here.details == "Generate sends your instruction, the sample shown below and any lines you marked as examples to the model at localhost:8080, on this Mac. Nothing else of the note, and no other note, is sent.")
        let near = ModelEndpointIndicator(host: "studio.local", locality: .localNetwork, place: .workbench)
        #expect(near.symbol == "△" && !near.isStrong && near.details.contains("studio.local, on your local network."))
        let far = ModelEndpointIndicator(host: "models.example", locality: .elsewhere, place: .workbench)
        #expect(far.symbol == "⚠︎" && far.isStrong, "the stronger mark")
        #expect(far.details.contains("to models.example, which is not this Mac or your local network: that text leaves the local network."))
        #expect(far.details.hasSuffix("Nothing else of the note, and no other note, is sent."))
        let settings = ModelEndpointIndicator(host: "models.example", locality: .elsewhere, place: .settings)
        #expect(settings.details.contains("the sample the script workbench shows") && settings.isStrong)
        #expect(ModelEndpointIndicator.mark != ModelEndpointIndicator.strongMark)

        let destination = ScriptGeneratorDestination(summary: "the model at models.example", host: "models.example", locality: .elsewhere)
        #expect(destination.indicator == far)
        #expect(destination.notice.hasSuffix("go to the model at models.example. That text leaves your local network."))
    }

    // MARK: The sample and the examples

    @Test func theSampleIsWhatFitsTheContext() {
        let fixed = ModelSampleBudget.tokens(in: ModelScriptPrompt.instructions(wholeText: false))
        let around = ModelSampleBudget.tokens(in: "Task: make links\n\nA sample of the text (the whole text has more lines like these):\n")
        let tokens = ModelSampleBudget.sampleTokens(context: 32_768, reply: 2_048, instruction: "make links", examples: [])
        #expect(tokens == 32_768 - 2_048 - 512 - fixed - around)
        #expect(tokens > 29_000, "nearly all of the context is the user's text")
        #expect(ModelSampleBudget.sampleBytes(context: 32_768, reply: 2_048, instruction: "make links", examples: []) == tokens * 3)
        #expect(ModelSampleBudget.tokens(in: "") == 0 && ModelSampleBudget.tokens(in: "a") == 1 && ModelSampleBudget.tokens(in: "abcd") == 2)
        #expect(ModelSampleBudget.tokens(in: "é") == 1 && ModelSampleBudget.tokens(in: "日本語") == 3, "bytes, not characters")
        #expect(ModelSampleBudget.sampleTokens(context: 2_048, reply: 4_096, instruction: "x", examples: []) == 0, "never negative")
        let example = ScriptExample(line: 3, text: String(repeating: "x", count: 300), expected: String(repeating: "y", count: 300))
        let withExample = ModelSampleBudget.sampleTokens(context: 32_768, reply: 2_048, instruction: "make links", examples: [example])
        #expect(tokens - withExample >= 200, "an example takes its room from the sample")

        let allowance = ScriptSampleAllowance.tokens(context: 32_768, reply: 2_048)
        let long = (1...40_000).map { "ticket \($0)" }.joined(separator: "\n")
        let sample = allowance.sample(of: long, instruction: "  make links ", examples: [])
        #expect(!sample.isWholeText && sample.totalLines == 40_000)
        #expect(sample.text.utf8.count <= tokens * 3 && sample.text.utf8.count > tokens * 3 - 20, "as much as fits, in whole lines")
        #expect(sample.text.split(separator: "\n").count > 40, "far more than the forty lines of a fixed sample")
        #expect(allowance.sample(of: "a\nb", instruction: "x", examples: []) == ScriptSample(text: "a\nb", isWholeText: true, totalLines: 2))
        // The whole request fits the context by the same estimate.
        let request = ScriptGenerationRequest(instruction: "make links", sample: sample)
        let sent = ModelChat.messages(for: request).map(\.content).reduce(0) { $0 + ModelSampleBudget.tokens(in: $1) }
        #expect(sent + 2_048 + 512 <= 32_768 + 2)

        let standard = ScriptSampleAllowance.standard.sample(of: long, instruction: "x", examples: [])
        #expect(standard.text.count <= 2_000 && standard.text.split(separator: "\n").count <= 40)
    }

    @Test func aSampleMeasuredInBytesCountsLineEndingsAndWideCharacters() {
        let text = "日本\r\n語\nabc"
        // 6 bytes, then 2 + 3 for the ending and the second line.
        #expect(ScriptSampling.sample(of: text, budget: 10, maxLines: .max, measure: { $0.utf8.count }).text == "日本")
        #expect(ScriptSampling.sample(of: text, budget: 11, maxLines: .max, measure: { $0.utf8.count }).text == "日本\r\n語")
        #expect(ScriptSampling.sample(of: text, budget: 15, maxLines: .max, measure: { $0.utf8.count }).isWholeText)
        #expect(ScriptSampling.sample(of: text, budget: 4, maxLines: .max, measure: { $0.utf8.count }).text == "日", "cut between characters")
        #expect(ScriptSampling.sample(of: text, budget: 2, maxLines: .max, measure: { $0.utf8.count }).text.isEmpty)
        #expect(ScriptSample(text: "a\nb", isWholeText: true, totalLines: 2).summary == "All of the text, 2 lines:")
        #expect(ScriptSample(text: "a", isWholeText: true, totalLines: 1).summary == "All of the text, 1 line:")
        #expect(ScriptSample(text: "a\nb", isWholeText: false, totalLines: 90).summary == "The first 2 of 90 lines:")
    }

    @Test func linesAreMarkedAsExamplesInLineOrder() throws {
        let target = "REG_A 1\n\nREG_B 2\r\nREG_C 3"
        var examples = try ScriptExamples.marking(line: 4, of: target, in: []).get()
        examples = try ScriptExamples.marking(line: 1, of: target, in: examples).get()
        #expect(examples == [ScriptExample(line: 1, text: "REG_A 1"), ScriptExample(line: 4, text: "REG_C 3")])
        examples[0].expected = "#define REG_A (1)"
        #expect(try ScriptExamples.marking(line: 1, of: target, in: examples).get() == examples, "marked before: kept, with what it should become")
        #expect(try ScriptExamples.marking(line: 3, of: target, in: examples).get().map(\.text) == ["REG_A 1", "REG_B 2", "REG_C 3"])
        #expect(ScriptExamples.marking(line: 2, of: target, in: []) == .failure(.init(reason: "Line 2 is empty, so it shows the model nothing.")))
        #expect(ScriptExamples.marking(line: 5, of: target, in: []) == .failure(.init(reason: "The text has 4 lines; there is no line 5.")))
        #expect(ScriptExamples.marking(line: 0, of: "a", in: []) == .failure(.init(reason: "The text has 1 line; there is no line 0.")))
        let many = (1...13).map { "line \($0)" }.joined(separator: "\n")
        var full: [ScriptExample] = []
        for line in 1...12 { full = try ScriptExamples.marking(line: line, of: many, in: full).get() }
        #expect(ScriptExamples.marking(line: 13, of: many, in: full) == .failure(.init(reason: "A request carries at most 12 examples.")))
        #expect(ScriptExample(line: 1, text: "a", expected: "  ").wanted == nil && examples[0].wanted == "#define REG_A (1)")
    }

    @Test func theRequestPutsTheExamplesAheadOfTheSample() {
        let sample = ScriptSample(text: "REG_A 1\nREG_B 2", isWholeText: false, totalLines: 90)
        let examples = [ScriptExample(line: 1, text: "REG_A 1", expected: "#define REG_A (1)"), ScriptExample(line: 70, text: "RESERVED")]
        let text = ModelScriptPrompt.request(instruction: "make defines", examples: examples, sample: sample)
        #expect(text == """
        Task: make defines

        Lines of the text marked as examples:
        This line:
        REG_A 1
        must become exactly:
        #define REG_A (1)

        A line the script must handle:
        RESERVED

        A sample of the text (the whole text has more lines like these):
        REG_A 1
        REG_B 2
        """)
        let whole = ModelScriptPrompt.request(instruction: "x", sample: ScriptSample(text: "a", isWholeText: true, totalLines: 1))
        #expect(whole == "Task: x\n\nThe text:\na")
        #expect(ModelScriptPrompt.instructions(wholeText: true).contains("You are shown the whole text."))
        #expect(ModelScriptPrompt.instructions(wholeText: false).contains("longer than the sample you are shown"))
        #expect(ModelScriptPrompt.instructions(wholeText: false).contains("function main(state)"))
    }

    // MARK: The request body

    func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aRequestCarriesTheDefaultsAndNothingExtra() throws {
        let messages = [ModelChat.Message(role: "system", content: "s"), ModelChat.Message(role: "user", content: "u")]
        let body = try json(try ModelChat.body(model: "coder", messages: messages, settings: .defaults).get())
        #expect(Set(body.keys) == ["model", "messages", "temperature", "top_p", "max_tokens", "stream"])
        #expect(body["model"] as? String == "coder")
        #expect(body["temperature"] as? Double == 0.2 && body["top_p"] as? Double == 1.0 && body["max_tokens"] as? Int == 2_048)
        #expect(body["stream"] as? Bool == false)
        #expect(body["messages"] as? [[String: String]] == [["role": "system", "content": "s"], ["role": "user", "content": "u"]])
    }

    @Test func aChangedSettingAndTheExtraFieldsAreInTheNextRequest() throws {
        var settings = ModelGenerationSettings.defaults
        settings.temperature = 0.9
        settings.topP = 0.5
        settings.maxReplyTokens = 4_096
        settings.extraFields = #"{"chat_template_kwargs":{"enable_thinking":false},"seed":7}"#
        let body = try json(try ModelChat.body(model: "m", messages: [], settings: settings).get())
        #expect(body["temperature"] as? Double == 0.9 && body["top_p"] as? Double == 0.5 && body["max_tokens"] as? Int == 4_096)
        #expect((body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false, "beside the standard ones")
        #expect(body["seed"] as? Int == 7)
        #expect(Set(body.keys) == ["model", "messages", "temperature", "top_p", "max_tokens", "stream", "chat_template_kwargs", "seed"])

        settings.extraFields = #"{"max_tokens":99,"temperature":0}"#
        guard case .failure(let taken) = ModelChat.body(model: "m", messages: [], settings: settings) else {
            Issue.record("a generation setting is not replaced from the extra fields")
            return
        }
        #expect(taken.reason.hasPrefix("\"max_tokens\" is set by BoopStash"))

        settings.extraFields = "enable_thinking=false"
        #expect(ModelChat.body(model: "m", messages: [], settings: settings)
            == .failure(.init(reason: "This is not valid JSON. It must be a JSON object, like {\"name\": value}.")))
        settings.extraFields = #"{"messages":[{"role":"user","content":"other"}]}"#
        guard case .failure = ModelChat.body(model: "m", messages: [], settings: settings) else {
            Issue.record("the conversation cannot be replaced")
            return
        }
        settings = .defaults
        settings.temperature = 50
        #expect(try json(try ModelChat.body(model: "m", messages: [], settings: settings).get())["temperature"] as? Double == 2, "never out of range")
    }

    // MARK: Reading the reply

    func completion(content: String?, finish: String = "stop", extra: [String: Any] = [:]) -> Data {
        var message: [String: Any] = ["role": "assistant"]
        if let content { message["content"] = content }
        for (key, value) in extra { message[key] = value }
        return try! JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "message": message, "finish_reason": finish]]])
    }

    @Test func aReplyCutOffAtTheLimitIsToldFromAnEmptyOne() {
        #expect(ModelChat.reply(in: completion(content: "hello")) == .content("hello", limited: false))
        #expect(ModelChat.reply(in: completion(content: "<think>hm</think>\n hello ")) == .content("hello", limited: false))
        // The three shapes of a reply that spent its allowance reasoning.
        #expect(ModelChat.reply(in: completion(content: "", finish: "length")) == .cutOff)
        #expect(ModelChat.reply(in: completion(content: nil, finish: "length", extra: ["reasoning_content": "thinking…"])) == .cutOff)
        #expect(ModelChat.reply(in: completion(content: "<think>still thinking", finish: "length")) == .cutOff)
        #expect(ModelChat.reply(in: completion(content: "answer <think>more", finish: "length")) == .content("answer", limited: true))
        #expect(ModelChat.reply(in: completion(content: "partial", finish: "length")) == .content("partial", limited: true))
        // No content and no limit to blame is not a cut-off.
        #expect(ModelChat.reply(in: completion(content: nil)) == .none)
        #expect(ModelChat.reply(in: completion(content: "")) == .content("", limited: false))
        #expect(ModelChat.reply(in: Data("{}".utf8)) == .none)
        #expect(ModelChat.reply(in: Data(#"{"choices":[]}"#.utf8)) == .none)
        #expect(ModelChat.reply(in: Data(#"{"choices":"x"}"#.utf8)) == .none)
        #expect(ModelChat.reply(in: Data("<html>".utf8)) == .none)
        #expect(ModelChat.withoutThinking("<think>a</think>x<think>b</think>y") == "xy")
        #expect(ModelChat.withoutThinking("<think>open") == "<think>open")
        // Only the closing tag: the template put the opening one in the prompt.
        #expect(ModelChat.withoutThinking("let me see…</think>\nanswer") == "answer")
        #expect(ModelChat.withoutThinking("a</think>b</think>c") == "c")
        #expect(ModelChat.withoutThinking("<think>a</think>x</think>y") == "y")
        #expect(ModelChat.withoutThinking("</think>") == "")
        #expect(ModelChat.reply(in: completion(content: "reasoning</think>```js\nfunction main(state) {}\n```"))
            == .content("```js\nfunction main(state) {}\n```", limited: false))
        #expect(ModelChat.reply(in: completion(content: "reasoning</think>", finish: "length")) == .cutOff)
        #expect(ModelChat.reply(in: completion(content: "reasoning</think>answer <think>more", finish: "length")) == .content("answer", limited: true))
    }

    @Test func theScriptIsTakenOutOfTheReply() {
        let script = "function main(state) {\n  state.text = state.text.trim();\n}"
        #expect(ModelScriptReply.extract("Here you go:\n```js\n\(script)\n```\nEnjoy.") == script)
        #expect(ModelScriptReply.extract(script) == script, "bare code")
        #expect(ModelScriptReply.extract("```js\nfunction main(state) { a }\n```\nFixed:\n```js\n\(script)\n```") == script, "the last block wins")
        #expect(ModelScriptReply.extract("```js\n\(script)") == script, "an open block counts for a reply that ended")
        #expect(ModelScriptReply.extract("I cannot do that.") == nil)
        #expect(ModelScriptReply.extract("```js\nconst main = (state) => {}\n```") == nil, "const binds a name the service cannot see")
        #expect(ModelScriptReply.extract("```\nvar main = function (state) {}\n```") == "var main = function (state) {}")
        #expect(ModelScriptReply.extract("") == nil)
        // At the token limit only a closed block is a whole script.
        #expect(ModelScriptReply.extract("```js\n\(script)\n```\nAnd then", closedBlocksOnly: true) == script)
        #expect(ModelScriptReply.extract("```js\n\(script)", closedBlocksOnly: true) == nil)
        #expect(ModelScriptReply.extract(script, closedBlocksOnly: true) == nil)
        #expect(ModelScriptReply.extract("```js\n\(script)\n```\n```js\nfunction main(state) { half", closedBlocksOnly: true) == script)
    }

    @Test func aServicesErrorBodyIsReadInTheShapesServersUse() {
        #expect(ModelChat.errorMessage(in: Data(#"{"error":{"message":" model not found ","type":"x"}}"#.utf8)) == "model not found")
        #expect(ModelChat.errorMessage(in: Data(#"{"error":"bad request"}"#.utf8)) == "bad request")
        #expect(ModelChat.errorMessage(in: Data(#"{"message":"nope"}"#.utf8)) == "nope")
        #expect(ModelChat.errorMessage(in: Data(#"{"detail":"unsupported field"}"#.utf8)) == "unsupported field")
        #expect(ModelChat.errorMessage(in: Data(#"{"error":{}}"#.utf8)) == nil)
        #expect(ModelChat.errorMessage(in: Data(#"{"error":{"message":""}}"#.utf8)) == nil)
        #expect(ModelChat.errorMessage(in: Data("<html>502</html>".utf8)) == nil)
        #expect(ModelChat.errorMessage(in: Data()) == nil)
        let long = ModelChat.errorMessage(in: try! JSONSerialization.data(withJSONObject: ["error": String(repeating: "x", count: 900)]))
        #expect(long?.count == 301 && long?.hasSuffix("…") == true)
    }

    @Test func theOutcomeSaysWhichWayARequestFailed() {
        func outcome(_ response: ModelServiceResponse, key: String? = nil) -> Result<String, ScriptGenerationFailure> {
            ModelChat.outcome(of: response, host: "studio.local", timeLimit: 180, apiKey: key)
        }
        let script = "function main(state) {}"
        #expect(outcome(.init(status: 200, body: completion(content: "```js\n\(script)\n```"))) == .success(script))
        #expect(outcome(.init(status: 200, body: completion(content: "Sorry, no."))) == .failure(.noScript))
        #expect(outcome(.init(status: 200, body: completion(content: "", finish: "length"))) == .failure(.cutOff))
        #expect(outcome(.init(status: 200, body: completion(content: "```js\n\(script)", finish: "length"))) == .failure(.cutOff), "never half a script")
        #expect(outcome(.init(status: 200, body: completion(content: "```js\n\(script)\n```", finish: "length"))) == .success(script))
        #expect(outcome(.init(status: 200, body: Data("{}".utf8)))
            == .failure(.failed("studio.local answered, but not with a chat completion. Check the base URL in Settings ▸ Model.")))
        #expect(outcome(.init(failure: .unreachable("Could not connect to the server.")))
            == .failure(.unavailable("The model at studio.local could not be reached: Could not connect to the server.")))
        #expect(outcome(.init(failure: .timedOut)) == .failure(.failed(
            "The model at studio.local did not answer within 180 seconds. It may still be loading; try again, or raise the time limit in Settings ▸ Model.")))
        #expect(outcome(.init(failure: .cancelled)) == .failure(.cancelled))
        #expect(outcome(.init(failure: .tooLarge)) == .failure(.failed("The reply from studio.local was larger than 4 MB and was dropped.")))
        #expect(outcome(.init(failure: .certificate("The certificate is not trusted.")))
            == .failure(.failed("The connection to studio.local is not trusted, so nothing was sent: The certificate is not trusted.")))
        #expect(outcome(.init(failure: .redirected)) == .failure(.failed(
            "studio.local answered with a redirect, which BoopStash does not follow. Enter the address it points to as the base URL.")))
        #expect(outcome(.init(failure: .refused("No."))) == .failure(.failed("No.")))
        #expect(outcome(.init(failure: .failed("Boom."))) == .failure(.failed("The request to studio.local failed: Boom.")))
        // A setting the service rejects is reported with its message.
        #expect(outcome(.init(status: 400, body: Data(#"{"error":{"message":"unknown field chat_template_kwargs"}}"#.utf8)))
            == .failure(.failed("studio.local answered with an error (HTTP 400): unknown field chat_template_kwargs")))
        #expect(outcome(.init(status: 502, body: Data("<html>".utf8))) == .failure(.failed("studio.local answered with an error (HTTP 502).")))
        #expect(outcome(.init(status: 401, body: Data(#"{"error":"bad key sk-secret-1"}"#.utf8)), key: "sk-secret-1")
            == .failure(.failed("studio.local answered with an error (HTTP 401): bad key (the API key) Check the API key in Settings ▸ Model.")))
        #expect(ScriptGenerationFailure.cutOff.message
            == "The model ran out of reply tokens before it answered. Switch its reasoning off (Settings ▸ Model ▸ extra request fields) or raise the maximum reply.")
    }

    @Test func aFailedLoadIsNamedByItsCode() {
        typealias Failure = ModelServiceResponse.Failure
        #expect(Failure(urlErrorCode: NSURLErrorTimedOut, description: "d") == .timedOut)
        #expect(Failure(urlErrorCode: NSURLErrorCancelled, description: "d") == .cancelled)
        #expect(Failure(urlErrorCode: NSURLErrorCannotConnectToHost, description: "d") == .unreachable("d"))
        #expect(Failure(urlErrorCode: NSURLErrorCannotFindHost, description: "d") == .unreachable("d"))
        #expect(Failure(urlErrorCode: NSURLErrorServerCertificateUntrusted, description: "d") == .certificate("d"))
        #expect(Failure(urlErrorCode: NSURLErrorServerCertificateHasUnknownRoot, description: "d") == .certificate("d"))
        #expect(Failure(urlErrorCode: NSURLErrorSecureConnectionFailed, description: "d") == .certificate("d"))
        #expect(Failure(urlErrorCode: NSURLErrorAppTransportSecurityRequiresSecureConnection, description: "d")
            == .refused("macOS allows plain http:// for local addresses only. Use https:// for this host."))
        #expect(Failure(urlErrorCode: NSURLErrorBadServerResponse, description: "d") == .failed("d"))
    }

    // MARK: The model list

    @Test func theModelListIsReadInOpenAIsShape() {
        let body = #"{"object":"list","data":[{"id":"coder","object":"model","owned_by":"me"},{"id":"flash"},{"id":"coder"},{"id":""},{"name":"x"},7]}"#
        #expect(ModelList.parse(Data(body.utf8)) == ["coder", "flash"], "extra fields ignored, no repeats")
        #expect(ModelList.parse(Data(#"{"data":[]}"#.utf8)) == [])
        #expect(ModelList.parse(Data(#"{"models":[]}"#.utf8)) == nil)
        #expect(ModelList.parse(Data(#"{"data":"x"}"#.utf8)) == nil)
        #expect(ModelList.parse(Data("not json".utf8)) == nil)
        #expect(ModelList.parse(Data()) == nil)

        func outcome(_ response: ModelServiceResponse) -> Result<[String], ModelListFailure> {
            ModelList.outcome(of: response, host: "studio.local", timeLimit: 15)
        }
        #expect(outcome(.init(status: 200, body: Data(#"{"data":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#.utf8))) == .success(["a", "b", "c"]))
        #expect(outcome(.init(status: 200, body: Data("<html>".utf8))) == .failure(.init(reason: "studio.local answered, but not with a list of models.")))
        #expect(outcome(.init(status: 404, body: Data())) == .failure(.init(reason: "studio.local answered with an error (HTTP 404).")))
        #expect(outcome(.init(failure: .unreachable("Down."))) == .failure(.init(reason: "The model at studio.local could not be reached: Down.")))
    }

    @Test func aChosenModelTheServiceStoppedListingStaysAndSaysSo() {
        #expect(ModelList.options(listed: ["a", "b"], chosen: "b").map(\.title) == ["a", "b"])
        let gone = ModelList.options(listed: ["a", "b"], chosen: " old ")
        #expect(gone.map(\.title) == ["old (not offered by the service)", "a", "b"])
        #expect(gone.map(\.isOffered) == [false, true, true] && gone[0].name == "old")
        #expect(ModelList.options(listed: ["a"], chosen: "").map(\.name) == ["a"])
        #expect(ModelList.options(listed: [], chosen: "typed").map(\.name) == ["typed"])
    }

    // MARK: What the helper is handed

    @Test func theHelpersRequestHasFixedHeadersAndOnlyTheKeyOfTheUsers() throws {
        let body = Data(#"{"model":"m"}"#.utf8)
        let chat = try ModelServiceRequest(call: .chat, baseURL: "http://localhost:8080", apiKey: " sk-test-1 ", body: body, timeLimit: 30).urlRequest().get()
        #expect(chat.url?.absoluteString == "http://localhost:8080/v1/chat/completions" && chat.httpMethod == "POST")
        #expect(chat.httpBody == body && chat.timeoutInterval == 30 && !chat.httpShouldHandleCookies)
        #expect(chat.allHTTPHeaderFields == [
            "Content-Type": "application/json", "Accept": "application/json", "User-Agent": "BoopStash",
            "Accept-Language": "en", "Authorization": "Bearer sk-test-1",
        ])
        let list = try ModelServiceRequest(call: .models, baseURL: "https://models.example/v1/", apiKey: nil, body: nil, timeLimit: 15).urlRequest().get()
        #expect(list.url?.absoluteString == "https://models.example/v1/models" && list.httpMethod == "GET" && list.httpBody == nil)
        #expect(list.allHTTPHeaderFields == ["Accept": "application/json", "User-Agent": "BoopStash", "Accept-Language": "en"])
        let blank = try ModelServiceRequest(call: .models, baseURL: "http://localhost", apiKey: "  ", body: nil, timeLimit: 15).urlRequest().get()
        #expect(blank.value(forHTTPHeaderField: "Authorization") == nil)

        // The helper checks the address again, by the same rule.
        #expect(ModelServiceRequest(call: .chat, baseURL: "http://models.example", apiKey: nil, body: body, timeLimit: 30).urlRequest()
            == .failure(.refused(ModelEndpointAddress.Problem.plainHTTP(host: "models.example").message)))
        #expect(ModelServiceRequest(call: .chat, baseURL: "file:///etc/hosts", apiKey: nil, body: body, timeLimit: 30).urlRequest()
            == .failure(.refused("The base URL must start with http:// or https://.")))
        #expect(ModelServiceRequest(call: .chat, baseURL: "http://localhost", apiKey: nil, body: nil, timeLimit: 30).urlRequest()
            == .failure(.refused("A chat request needs a body.")))
        #expect(ModelServiceRequest(call: .models, baseURL: "http://localhost", apiKey: nil, body: body, timeLimit: 30).urlRequest()
            == .failure(.refused("A model list request carries no body.")))
        #expect(ModelServiceRequest.limit(0) == 5 && ModelServiceRequest.limit(1e9) == 1_800 && ModelServiceRequest.limit(.nan) == 1_800)
    }

    @Test func aRequestThatIsPrintedShowsNeitherTheKeyNorTheText() throws {
        let request = ModelServiceRequest(call: .chat, baseURL: "http://studio.local", apiKey: "sk-secret-1", body: Data("note text".utf8), timeLimit: 30)
        for printed in ["\(request)", String(describing: request), String(reflecting: request), "\([request])"] {
            #expect(printed.contains("ModelServiceRequest(chat)"))
            #expect(!printed.contains("sk-secret-1") && !printed.contains("studio.local") && !printed.contains("note"))
        }
        // It still crosses to the helper whole.
        let decoded = try JSONDecoder().decode(ModelServiceRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request && decoded.apiKey == "sk-secret-1")
        let response = ModelServiceResponse(failure: .unreachable("Down."))
        #expect(try JSONDecoder().decode(ModelServiceResponse.self, from: JSONEncoder().encode(response)) == response)
        let answered = ModelServiceResponse(status: 200, body: Data("{}".utf8))
        #expect(try JSONDecoder().decode(ModelServiceResponse.self, from: JSONEncoder().encode(answered)) == answered)
    }

    // MARK: The generator

    /// Stands in for the helper: records what it was handed.
    actor FakeHelper {
        var requests: [ModelServiceRequest] = []
        let response: ModelServiceResponse
        let hangs: Bool

        init(_ response: ModelServiceResponse, hangs: Bool = false) {
            self.response = response
            self.hangs = hangs
        }

        func send(_ request: ModelServiceRequest) async -> ModelServiceResponse {
            requests.append(request)
            if hangs {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return ModelServiceResponse(failure: .cancelled)
            }
            return response
        }
    }

    static let script = "function main(state) {\n  state.text = state.text.toUpperCase();\n}"

    func generator(_ settings: ModelEndpointSettings, key: String? = nil, helper: FakeHelper) -> ModelEndpointGenerator {
        ModelEndpointGenerator(settings: { settings }, apiKey: { key }, transport: { await helper.send($0) })
    }

    func ok() -> ModelServiceResponse {
        ModelServiceResponse(status: 200, body: completion(content: "```js\n\(Self.script)\n```"))
    }

    @Test func withNothingConfiguredThereIsNoGeneratorToSpeakOfAndTheHelperIsNeverCalled() async {
        let helper = FakeHelper(ok())
        let off = generator(ModelEndpointSettings(), helper: helper)
        #expect(await off.availability() == .notConfigured)
        #expect(ScriptGeneration.destination(await off.availability()) == nil)
        #expect(ScriptGeneration.unavailableReason(await off.availability()) == nil)
        let sample = ScriptSample(text: "a", isWholeText: true, totalLines: 1)
        #expect(await off.generate(ScriptGenerationRequest(instruction: "x", sample: sample))
            == .failure(.unavailable("No model is set up in Settings ▸ Model.")))
        #expect(await helper.requests.isEmpty)
    }

    @Test func aGeneratorThatIsSetUpButIncompleteSaysWhyAndSendsNothing() async {
        let helper = FakeHelper(ok())
        let noModel = generator(ModelEndpointSettings(baseURL: "http://localhost:8080"), helper: helper)
        #expect(await noModel.availability() == .unavailable(reason: "No model is chosen in Settings ▸ Model."))
        var settings = ModelEndpointSettings(baseURL: "http://localhost:8080", model: "m")
        settings.generation.extraFields = "nope"
        let badExtras = generator(settings, helper: helper)
        #expect(ScriptGeneration.unavailableReason(await badExtras.availability())?.contains("This is not valid JSON.") == true)
        let sample = ScriptSample(text: "a", isWholeText: true, totalLines: 1)
        guard case .failure(.unavailable) = await badExtras.generate(ScriptGenerationRequest(instruction: "x", sample: sample)) else {
            Issue.record("no request is made with extra fields that are not an object")
            return
        }
        #expect(await helper.requests.isEmpty, "asking whether it is available sends nothing either")
    }

    @Test func availabilityNamesTheHostAndWhereItIs() async {
        let helper = FakeHelper(ok())
        var settings = ModelEndpointSettings(baseURL: "https://models.example", model: "m")
        settings.generation.contextLength = 8_192
        settings.generation.maxReplyTokens = 1_000
        let availability = await generator(settings, helper: helper).availability()
        #expect(availability == .available(ScriptGeneratorDestination(
            summary: "the model at models.example", host: "models.example", locality: .elsewhere,
            allowance: .tokens(context: 8_192, reply: 1_000))))
        #expect(ScriptGeneration.destination(availability)?.indicator?.isStrong == true)
        #expect(await helper.requests.isEmpty)
    }

    @Test func aRequestHoldsTheInstructionTheShownSampleAndNothingElseOfTheNote() async throws {
        let helper = FakeHelper(ok())
        let settings = ModelEndpointSettings(baseURL: "http://studio.local:8080", model: " coder ")
        let generator = generator(settings, key: "sk-test-1", helper: helper)
        // The note is longer than the context: its tail must not be sent.
        let note = (1...60_000).map { "ticket \($0)" }.joined(separator: "\n") + "\nSECRET-TAIL"
        let destination = try #require(ScriptGeneration.destination(await generator.availability()))
        let shown = destination.allowance.sample(of: note, instruction: "make links", examples: [])
        #expect(!shown.isWholeText && !shown.text.contains("SECRET-TAIL"))
        let result = await ScriptGeneration.run(generator, instruction: " make links ", target: note, allowance: destination.allowance)
        #expect(result == .success(Self.script), "the script alone, without its fence")

        let request = try #require(await helper.requests.first)
        #expect(await helper.requests.count == 1)
        #expect(request.call == .chat && request.baseURL == "http://studio.local:8080" && request.apiKey == "sk-test-1")
        #expect(request.timeLimit == 180)
        let body = try json(try #require(request.body))
        #expect(Set(body.keys) == ["model", "messages", "temperature", "top_p", "max_tokens", "stream"], "the defaults and nothing extra")
        #expect(body["model"] as? String == "coder")
        #expect(body["temperature"] as? Double == 0.2 && body["top_p"] as? Double == 1.0 && body["max_tokens"] as? Int == 2_048)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0] == ["role": "system", "content": ModelScriptPrompt.instructions(wholeText: false)], "our fixed prompt")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == ModelScriptPrompt.request(instruction: "make links", sample: shown), "exactly the sample shown")
        let sent = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(!sent.contains("SECRET-TAIL") && !sent.contains("sk-test-1"), "the key is a header, never in the body")
    }

    @Test func markedExamplesGoAheadOfTheSampleAndAChangedSettingIsInTheNextRequest() async throws {
        let helper = FakeHelper(ok())
        var settings = ModelEndpointSettings(baseURL: "http://localhost:8080", model: "m")
        settings.generation.temperature = 0.8
        settings.generation.timeLimit = 60
        settings.generation.extraFields = #"{"chat_template_kwargs":{"enable_thinking":false}}"#
        let generator = generator(settings, helper: helper)
        let examples = [ScriptExample(line: 2, text: "REG_B 2", expected: "#define REG_B (2)")]
        let result = await ScriptGeneration.run(generator, instruction: "defines", target: "REG_A 1\nREG_B 2",
                                                examples: examples, allowance: .tokens(context: 32_768, reply: 2_048))
        #expect(result == .success(Self.script))
        let request = try #require(await helper.requests.first)
        #expect(request.apiKey == nil && request.timeLimit == 60)
        let body = try json(try #require(request.body))
        #expect(body["temperature"] as? Double == 0.8)
        #expect((body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool == false)
        let content = try #require((body["messages"] as? [[String: String]])?.last?["content"])
        let example = try #require(content.range(of: "This line:\nREG_B 2\nmust become exactly:\n#define REG_B (2)"))
        let sample = try #require(content.range(of: "The text:\nREG_A 1\nREG_B 2"))
        #expect(example.upperBound <= sample.lowerBound, "ahead of the sample")
        #expect((body["messages"] as? [[String: String]])?.first?["content"] == ModelScriptPrompt.instructions(wholeText: true))
    }

    @Test func examplesThatLeaveNoRoomForASampleAreNotSent() async {
        let helper = FakeHelper(ok())
        let generator = generator(ModelEndpointSettings(baseURL: "http://localhost", model: "m"), helper: helper)
        let huge = [ScriptExample(line: 1, text: String(repeating: "x", count: 20_000))]
        let result = await ScriptGeneration.run(generator, instruction: "x", target: "abc\ndef", examples: huge,
                                                allowance: .tokens(context: 4_096, reply: 2_048))
        #expect(result == .failure(.failed(
            "The instruction and the examples leave no room for a sample of the text. Remove examples, or raise the context length in Settings ▸ Model.")))
        #expect(await helper.requests.isEmpty)
    }

    @Test func theGeneratorSaysWhichWayItFailed() async {
        let sample = ScriptSample(text: "a", isWholeText: true, totalLines: 1)
        let request = ScriptGenerationRequest(instruction: "x", sample: sample)
        let settings = ModelEndpointSettings(baseURL: "http://studio.local", model: "m")
        func result(_ response: ModelServiceResponse) async -> Result<String, ScriptGenerationFailure> {
            await generator(settings, helper: FakeHelper(response)).generate(request)
        }
        #expect(await result(.init(failure: .unreachable("Down."))) == .failure(.unavailable("The model at studio.local could not be reached: Down.")))
        guard case .failure(.failed(let slow)) = await result(.init(failure: .timedOut)) else {
            Issue.record("slow past the limit is a failure of its own")
            return
        }
        #expect(slow.hasPrefix("The model at studio.local did not answer within 180 seconds."))
        #expect(await result(.init(status: 200, body: completion(content: "No."))) == .failure(.noScript))
        #expect(await result(.init(status: 200, body: completion(content: nil, finish: "length"))) == .failure(.cutOff))
        #expect(await result(.init(status: 500, body: Data(#"{"error":"out of memory"}"#.utf8)))
            == .failure(.failed("studio.local answered with an error (HTTP 500): out of memory")))

        struct Locked: Error {}
        let helper = FakeHelper(ok())
        let locked = ModelEndpointGenerator(settings: { settings }, apiKey: { throw Locked() }, transport: { await helper.send($0) })
        #expect(await locked.generate(request) == .failure(.unavailable("The API key could not be read from the Keychain, so no request was made.")))
        #expect(await helper.requests.isEmpty)
    }

    @Test func cancellingStopsTheRequest() async {
        let helper = FakeHelper(ok(), hangs: true)
        let generator = generator(ModelEndpointSettings(baseURL: "http://localhost", model: "m"), helper: helper)
        let task = Task { await ScriptGeneration.run(generator, instruction: "x", target: "a") }
        while await helper.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
    }

    @Test func theModelListRequestCarriesTheKeyAndNothingElse() async throws {
        let helper = FakeHelper(ModelServiceResponse(status: 200, body: Data(#"{"data":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#.utf8)))
        var settings = ModelEndpointSettings(baseURL: "http://studio.local:8080", model: "old")
        settings.generation.extraFields = #"{"seed":1}"#
        let listed = await ModelEndpointGenerator.models(settings: settings, apiKey: "sk-test-1", transport: { await helper.send($0) })
        #expect(listed == .success(["a", "b", "c"]))
        #expect(await helper.requests == [ModelServiceRequest(call: .models, baseURL: "http://studio.local:8080", apiKey: "sk-test-1", body: nil, timeLimit: 15)])

        let down = FakeHelper(ModelServiceResponse(failure: .unreachable("Down.")))
        #expect(await ModelEndpointGenerator.models(settings: settings, apiKey: nil, transport: { await down.send($0) })
            == .failure(.init(reason: "The model at studio.local:8080 could not be reached: Down.")))
        let unasked = FakeHelper(ok())
        settings.baseURL = "http://models.example"
        #expect(await ModelEndpointGenerator.models(settings: settings, apiKey: nil, transport: { await unasked.send($0) })
            == .failure(.init(reason: ModelEndpointAddress.Problem.plainHTTP(host: "models.example").message)))
        #expect(await unasked.requests.isEmpty)
    }
}
