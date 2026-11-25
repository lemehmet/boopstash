import Foundation
import Testing
@testable import BoopstashCore

/// The workbench's pure parts (#247): headers, name clashes, skeletons, the
/// sample a generator is shown, a run turned into a diff, and the generator
/// seam with a fake. The skeletons are run in the script service by the
/// app's tests; Core has no JavaScript engine.
@Suite struct ScriptWorkbenchTests {
    // MARK: Headers

    @Test func aHeaderReadsBackAsTheScriptItDescribes() throws {
        let file = ScriptHeader.file(name: "  Numbers to Links ", description: "Each number becomes a link.",
                                     tags: ["links", "numbers"], script: "function main(state) {}")
        #expect(file.hasPrefix("/**\n{\n  \"api\": 1,\n  \"name\": \"Numbers to Links\",\n"))
        #expect(file.hasSuffix("**/\n\nfunction main(state) {}\n"))
        let script = try BoopScript.parse(file, id: "user/NumbersToLinks.js", bundled: false).get()
        #expect(script.name == "Numbers to Links")
        #expect(script.description == "Each number becomes a link.")
        #expect(script.tags == ["links", "numbers"])
        #expect(script.author == nil && script.icon == nil)
    }

    @Test func emptyFieldsAreLeftOut() {
        #expect(ScriptHeader.make(name: "Plain", description: "  ", author: "", tags: []) == "/**\n{\n  \"api\": 1,\n  \"name\": \"Plain\"\n}\n**/\n")
    }

    @Test(arguments: [
        #"He said "hi" \ and left"#,
        "ends the comment **/ early",
        "opens another /** comment",
        "tab\there, control \u{1} end",
        "naïve café 日本語 🙂",
    ])
    func anyNameSurvivesTheHeader(name: String) throws {
        let file = ScriptHeader.file(name: name, description: name, script: "function main(state) {}")
        let script = try BoopScript.parse(file, id: "t", bundled: false).get()
        #expect(script.name == name)
        #expect(script.description == name)
        #expect(ScriptHeader.body(of: file) == "function main(state) {}\n", "the header ends where it should")
    }

    @Test func separatorsAndSlashesAreEscaped() {
        #expect(ScriptHeader.quoted("a\u{2028}b/\u{1}") == #""a\u2028b\/\u0001""#)
    }

    @Test func aNameIsOneLine() throws {
        #expect(ScriptHeader.cleanName(" two\nlines\r\nhere ") == "two lines here")
        let file = ScriptHeader.file(name: "two\nlines", script: "function main(state) {}")
        #expect(try BoopScript.parse(file, id: "t", bundled: false).get().name == "two lines")
    }

    @Test func theBodyIsTheScriptWithoutItsHeader() {
        let body = "function main(state) { state.text = '/** not a header **/' }\n"
        #expect(ScriptHeader.body(of: "/**\n{\"api\":1,\"name\":\"Old\"}\n**/\n\n" + body) == body)
        #expect(ScriptHeader.body(of: "\n  /** {\"name\":\"Old\"} **/" + body) == body)
        #expect(ScriptHeader.body(of: body) == body, "no header: as it is")
        let commented = "/** just a comment **/\n" + body
        #expect(ScriptHeader.body(of: commented) == commented, "a comment that is not a Boop header stays")
        let later = "var x = 1;\n/** {\"name\":\"Later\"} **/\n" + body
        #expect(ScriptHeader.body(of: later) == later, "a header after code is not the script's header")
    }

    @Test func savingAnAdaptedScriptReplacesItsHeader() throws {
        let old = "/**\n{\"api\":1,\"name\":\"Old Name\",\"description\":\"old\"}\n**/\nfunction main(state) {}"
        let file = ScriptHeader.file(name: "New Name", script: old)
        #expect(file.components(separatedBy: "/**").count == 2, "one header")
        let script = try BoopScript.parse(file, id: "t", bundled: false).get()
        #expect(script.name == "New Name" && script.description.isEmpty)
    }

    // MARK: Saving

    let mine = [ScriptSave.Existing(fileName: "Shout.js", scriptName: "Shout"),
                ScriptSave.Existing(fileName: "NumbersToLinks.js", scriptName: "Something Else"),
                ScriptSave.Existing(fileName: "Broken.js", scriptName: nil)]

    @Test func aNewNameIsANewFile() {
        #expect(ScriptSave.plan(name: "Defines from Table", existing: mine, bundledNames: ["Sort Lines"]) == .write(fileName: "DefinesFromTable.js"))
        #expect(ScriptSave.plan(name: "x", existing: [], bundledNames: []) == .write(fileName: "X.js"))
    }

    @Test func aNameIsNeeded() {
        #expect(ScriptSave.plan(name: " \n ", existing: [], bundledNames: []) == .refused("Give the script a name."))
    }

    @Test func aNameOfTheUsersOwnAsksBeforeReplacingThatFile() {
        let plan = ScriptSave.plan(name: " shout ", existing: mine, bundledNames: [])
        #expect(plan == .clash(.yours(fileName: "Shout.js"), fileName: "Shout.js"))
        #expect(plan.question(name: "shout") == "You already have a script named shout. Replace it?")
    }

    @Test func aBundledNameAsksAndWritesANewFile() {
        let plan = ScriptSave.plan(name: "sort lines", existing: mine, bundledNames: ["Sort Lines", "Clean Up Pasted Text"])
        #expect(plan == .clash(.bundled, fileName: "SortLines.js"))
        #expect(plan.question(name: "sort lines")?.contains("comes with BoopStash") == true)
        #expect(ScriptSave.Plan.write(fileName: "A.js").question(name: "A") == nil)
    }

    @Test func aNewFileNeverTakesAnExistingFilesName() {
        // Another script's file, and one that does not even parse.
        #expect(ScriptSave.plan(name: "Numbers to Links", existing: mine, bundledNames: []) == .write(fileName: "NumbersToLinks2.js"))
        #expect(ScriptSave.plan(name: "broken", existing: mine, bundledNames: []) == .write(fileName: "Broken2.js"))
        let more = mine + [ScriptSave.Existing(fileName: "numberstolinks2.JS", scriptName: nil)]
        #expect(ScriptSave.plan(name: "Numbers to Links", existing: more, bundledNames: []) == .write(fileName: "NumbersToLinks3.js"))
    }

    @Test func fileNamesAreLettersAndDigits() {
        #expect(ScriptSave.fileStem(for: "numbers → links (v2)") == "NumbersLinksV2")
        #expect(ScriptSave.fileStem(for: "../../etc/hosts") == "EtcHosts")
        #expect(ScriptSave.fileStem(for: "→ / .") == "Script")
        #expect(ScriptSave.fileStem(for: "café 日本") == "Café日本")
        #expect(ScriptSave.fileStem(for: String(repeating: "a", count: 200)).count == 60)
    }

    // MARK: Skeletons

    @Test func everySkeletonDefinesMainAndSavesAsAScript() throws {
        #expect(ScriptSkeleton.allCases.map(\.name) == ["Blank Script", "Line by Line", "Rows with Wrapped Descriptions"])
        for skeleton in ScriptSkeleton.allCases {
            #expect(skeleton.source.contains("function main(state) {"), "\(skeleton)")
            #expect(skeleton.source.hasSuffix("}\n"))
            #expect(!skeleton.summary.isEmpty)
            #expect(ScriptHeader.body(of: skeleton.source) == skeleton.source, "no header of its own")
            let file = ScriptHeader.file(name: skeleton.name, script: skeleton.source)
            #expect(try BoopScript.parse(file, id: "t", bundled: false).get().name == skeleton.name)
        }
    }

    @Test func theSkeletonsEscapesReachJavaScriptAsWritten() {
        #expect(ScriptSkeleton.lineByLine.source.contains(#"state.text.split("\n")"#))
        #expect(ScriptSkeleton.lineByLine.source.contains(#"out.join("\n")"#))
        #expect(ScriptSkeleton.wrappedRows.source.contains(#"/^(\S+)\s+(\d+)\b\s*(.*)$/"#))
    }

    // MARK: The sample

    @Test func aShortTargetIsItsOwnSample() {
        let text = "12\n34\n\n56\n"
        #expect(ScriptSampling.sample(of: text) == ScriptSample(text: text, isWholeText: true, totalLines: 5))
        #expect(ScriptSampling.sample(of: "") == ScriptSample(text: "", isWholeText: true, totalLines: 1))
        #expect(ScriptSampling.sample(of: "abc\nde", budget: 6).isWholeText, "exactly the budget fits")
    }

    @Test func aLongTargetGivesItsLeadingWholeLines() {
        let text = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let sample = ScriptSampling.sample(of: text, budget: 100, maxLines: 40)
        #expect(!sample.isWholeText)
        #expect(sample.totalLines == 500)
        #expect(sample.text.count <= 100)
        #expect(text.hasPrefix(sample.text + "\n"), "whole lines from the start")
        #expect(sample.text.hasSuffix("line 13"))
        #expect(ScriptSampling.sample(of: text, budget: 101, maxLines: 40).text.hasSuffix("line 13"), "the line feed counts")
        #expect(ScriptSampling.sample(of: text, budget: 102, maxLines: 40).text.hasSuffix("line 14"))
    }

    @Test func theLineLimitHoldsWhenTheBudgetDoesNot() {
        let text = (1...500).map(String.init).joined(separator: "\n")
        let sample = ScriptSampling.sample(of: text, budget: 10_000, maxLines: 40)
        #expect(sample.text == (1...40).map(String.init).joined(separator: "\n"))
        #expect(!sample.isWholeText)
        let defaults = ScriptSampling.sample(of: String(repeating: "0123456789\n", count: 1_000))
        #expect(defaults.text.count <= ScriptSampling.defaultBudget)
        #expect(defaults.text.split(separator: "\n").count <= ScriptSampling.defaultMaxLines)
    }

    @Test func windowsLineEndingsAreLinesTooAndStayAsTheyAre() {
        let text = (1...100).map { "row \($0)" }.joined(separator: "\r\n")
        let sample = ScriptSampling.sample(of: text, budget: 30)
        #expect(sample.text == "row 1\r\nrow 2\r\nrow 3\r\nrow 4\r\nrow 5")
        #expect(sample.totalLines == 100 && !sample.isWholeText)
        #expect(ScriptSampling.sample(of: "a\r\nb\nc", budget: 5) == ScriptSample(text: "a\r\nb\nc", isWholeText: true, totalLines: 3))
    }

    @Test func aFirstLineLongerThanTheBudgetIsCutBetweenCharacters() {
        let flag = "🇨🇭"
        let text = String(repeating: flag, count: 50) + "\nsecond"
        let sample = ScriptSampling.sample(of: text, budget: 7)
        #expect(sample.text == String(repeating: flag, count: 7))
        #expect(!sample.isWholeText && sample.totalLines == 2)
        #expect(ScriptSampling.sample(of: text, budget: 0).text.isEmpty)
        #expect(ScriptSampling.sample(of: text, budget: -5).text.isEmpty)
    }

    // MARK: A run

    func whole(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

    @Test func aRunBecomesADiffAndTheEditsToKeep() {
        let text = "12\n34\n"
        let result = ScriptWorkbenchResult.make(response: ScriptResponse(outputs: ["#12\n#34\n"], infos: ["2 lines"]),
                                                fullText: text, selections: [NSRange(location: 3, length: 0)])
        #expect(result.canKeep)
        #expect(result.edits?.count == 1 && result.edits?[0].0 == whole(text) && result.edits?[0].1 == "#12\n#34\n")
        #expect(result.content.summary == TextDiff.Summary(removed: 2, added: 2))
        #expect(result.status == "2 lines removed, 2 added")
        #expect(result.notes.map(\.kind) == [.info] && result.notes.map(\.text) == ["2 lines"])
    }

    @Test func aRunOnASelectionDiffsOnlyTheSelection() {
        let text = "keep\n12\nkeep\n"
        let selection = NSRange(location: 5, length: 2)
        let result = ScriptWorkbenchResult.make(response: ScriptResponse(outputs: ["#12"]), fullText: text, selections: [selection])
        #expect(result.edits?.first?.0 == selection)
        #expect(result.content.parts.count == 1 && result.content.parts[0].firstLine == 2)
        #expect(!result.content.parts.flatMap(\.hunks).flatMap(\.lines).contains { $0.text == "keep" })
    }

    @Test func aFailedRunHasNothingToKeep() {
        let stopped = "Workbench Script took longer than 2 seconds and was stopped."
        let result = ScriptWorkbenchResult.make(response: ScriptResponse(outputs: [], errors: [stopped], infos: ["started"]),
                                                fullText: "a", selections: [])
        #expect(!result.canKeep && result.edits == nil && result.content.isEmpty)
        #expect(result.status == "The script failed. Nothing to keep.")
        #expect(result.notes.map(\.kind) == [.error, .info], "errors first")
        #expect(result.notes.first?.text == stopped)
        #expect(Set(result.notes.map(\.id)).count == 2)
    }

    @Test func aRunThatChangesNothingSaysSo() {
        let result = ScriptWorkbenchResult.make(response: ScriptResponse(outputs: ["same\n"]), fullText: "same\n", selections: [])
        #expect(!result.canKeep && result.edits == nil)
        #expect(result.status == "The script ran and would change nothing.")
    }

    @Test func anAnswerThatDoesNotFitTheSelectionsIsNoResult() {
        let none = ScriptWorkbenchResult.make(response: ScriptResponse(outputs: []), fullText: "a", selections: [])
        #expect(!none.canKeep && none.status == "The run gave no result.")
        let two = ScriptWorkbenchResult.make(response: ScriptResponse(outputs: ["x", "y"]), fullText: "abc",
                                             selections: [NSRange(location: 0, length: 1)])
        #expect(!two.canKeep && two.status == "The run gave no result.")
    }

    @Test func theTargetIsNamed() {
        #expect(ScriptWorkbenchResult.targetDescription(selections: [NSRange(location: 4, length: 0)]) == "The whole note")
        #expect(ScriptWorkbenchResult.targetDescription(selections: [NSRange(location: 4, length: 2)]) == "The selection")
        #expect(ScriptWorkbenchResult.targetDescription(selections: [NSRange(location: 0, length: 1), NSRange(location: 4, length: 2)]) == "2 selections")
    }

    // MARK: The generator seam

    /// Stands in for a model: records what it was asked and answers as told.
    actor FakeGenerator: ScriptGenerator {
        var requests: [ScriptGenerationRequest] = []
        let answer: Result<String, ScriptGenerationFailure>
        let state: ScriptGeneratorAvailability
        let waits: Bool

        init(answer: Result<String, ScriptGenerationFailure> = .success("function main(state) {}"),
             state: ScriptGeneratorAvailability = .available(ScriptGeneratorDestination(summary: "a fake")),
             waits: Bool = false) {
            self.answer = answer
            self.state = state
            self.waits = waits
        }

        func availability() async -> ScriptGeneratorAvailability { state }

        func generate(_ request: ScriptGenerationRequest) async -> Result<String, ScriptGenerationFailure> {
            requests.append(request)
            if waits {
                // Until cancelled, as a slow model would be.
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return .failure(.cancelled)
            }
            return answer
        }
    }

    @Test func aGeneratorGetsTheInstructionAndABoundedSample() async {
        let generator = FakeGenerator()
        let target = (1...500).map { "ticket \($0)" }.joined(separator: "\n")
        let result = await ScriptGeneration.run(generator, instruction: "  make links \n", target: target, budget: 60)
        #expect(result == .success("function main(state) {}"))
        let request = await generator.requests.first
        #expect(request?.instruction == "make links")
        #expect(request?.sample.isWholeText == false)
        #expect((request?.sample.text.count ?? .max) <= 60)
        #expect(request?.sample.totalLines == 500)
    }

    @Test func anEmptyInstructionIsNotSent() async {
        let generator = FakeGenerator()
        let result = await ScriptGeneration.run(generator, instruction: " \n", target: "a")
        #expect(result == .failure(.failed("Say what the script should do.")))
        #expect(await generator.requests.isEmpty)
    }

    @Test func aBlankScriptIsNoScriptAndAFailureKeepsItsReason() async {
        #expect(await ScriptGeneration.run(FakeGenerator(answer: .success(" \n")), instruction: "x", target: "a") == .failure(.noScript))
        let refused = FakeGenerator(answer: .failure(.failed("The model did not answer.")))
        #expect(await ScriptGeneration.run(refused, instruction: "x", target: "a") == .failure(.failed("The model did not answer.")))
        #expect(ScriptGenerationFailure.noScript.message == "The reply held no script with a main function.")
        #expect(ScriptGenerationFailure.unavailable("Not set up.").message == "Not set up.")
        #expect(ScriptGenerationFailure.cancelled.message == nil, "the user's own cancel needs no message")
    }

    @Test func cancellingTheTaskCancelsTheRequest() async {
        let generator = FakeGenerator(waits: true)
        let task = Task { await ScriptGeneration.run(generator, instruction: "x", target: "a") }
        while await generator.requests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        #expect(await task.value == .failure(.cancelled))
    }

    @Test func theSheetOffersGenerateOnlyForAnAvailableGenerator() async {
        let here = ScriptGeneratorDestination(summary: "the model on this Mac")
        #expect(ScriptGeneration.destination(nil) == nil, "no generator: no prompt field, no Generate")
        #expect(ScriptGeneration.destination(.unavailable(reason: "No model is set up.")) == nil)
        #expect(ScriptGeneration.destination(await FakeGenerator(state: .available(here)).availability()) == here)
        #expect(here.notice == "Your instruction and a sample of the text go to the model on this Mac.")
    }
}
