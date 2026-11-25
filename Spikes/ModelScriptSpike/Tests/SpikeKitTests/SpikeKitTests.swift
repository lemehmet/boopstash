import Testing
@testable import SpikeKit

@Suite struct ScriptReplyTests {
    @Test func takesTheFencedBlockAndDropsTheProse() {
        let reply = "Here you go:\n```js\nfunction main(state) {\n  state.text = 'x';\n}\n```\nHope it helps."
        #expect(ScriptReply.extract(reply) == "function main(state) {\n  state.text = 'x';\n}")
    }

    @Test func takesBareCode() {
        #expect(ScriptReply.extract("  function main(state) {}\n") == "function main(state) {}")
    }

    @Test func prefersTheLastBlockThatDefinesMain() {
        let reply = "```\nconst a = 1;\n```\n```javascript\nfunction main (state) { }\n```\n```js\nmain = (state) => {}\n```\n```\nstate.text\n```"
        #expect(ScriptReply.extract(reply) == "main = (state) => {}")
    }

    @Test func takesABlockThatWasCutOff() {
        #expect(ScriptReply.extract("```js\nfunction main(state) {\n  state.text =") == "function main(state) {\n  state.text =")
    }

    @Test func refusesAReplyWithoutMain() {
        #expect(ScriptReply.extract("I can't help with that.") == nil)
        #expect(ScriptReply.extract("```js\nfunction transform(text) { return text; }\n```") == nil)
        #expect(ScriptReply.extract("") == nil)
    }

    @Test func takesAnOpenBlockAfterAClosedOne() {
        let reply = "```text\nexample\n```\n```js\nfunction main(state) { state.text = 'x'; }"
        #expect(ScriptReply.extract(reply) == "function main(state) { state.text = 'x'; }")
        #expect(ScriptReply.extract("```js\nfunction main(state) {}\n```\n```\nnotes") == "function main(state) {}")
    }

    @Test func recognisesWaysToDefineMain() {
        #expect(ScriptReply.definesMain("var main = async (state) => {}"))
        #expect(ScriptReply.definesMain("main = function (state) {}"))
        #expect(ScriptReply.definesMain("const helper = 1;\nmain = state => {}"))
        #expect(ScriptReply.definesMain("async function main(state) {}"))
    }

    /// The script service finds `main` on the global object, where `const`
    /// and `let` put nothing.
    @Test func aConstOrLetMainIsNotAMain() {
        #expect(!ScriptReply.definesMain("const main = function (state) {}"))
        #expect(!ScriptReply.definesMain("let main = state => {}"))
        #expect(!ScriptReply.definesMain("exports.main = (state) => {}"))
        #expect(ScriptReply.extract("```js\nconst main = (state) => {}\n```") == nil)
        #expect(!ScriptReply.definesMain("domain = 3"))
        #expect(!ScriptReply.definesMain("// call main(state)"))
    }
}

@Suite struct ScoreTests {
    @Test func passesWhenOnlyTrailingSpaceDiffers() {
        #expect(Score.compare(actual: "a  \r\nb\n\n", expected: "a\nb") == .pass)
    }

    @Test func reportsTheFirstWrongLine() {
        #expect(Score.compare(actual: "a\nx\nc", expected: "a\nb\nc") == .wrong(line: 2, expected: "b", actual: "x", matching: 2, of: 3))
    }

    @Test func reportsMissingAndExtraLines() {
        #expect(Score.compare(actual: "a", expected: "a\nb") == .wrong(line: 2, expected: "b", actual: nil, matching: 1, of: 2))
        #expect(Score.compare(actual: "a\nb", expected: "a") == .wrong(line: 2, expected: nil, actual: "b", matching: 1, of: 1))
    }

    @Test func anEmptyLineIsNotAMissingLine() {
        #expect(Score.compare(actual: "\nb", expected: "a\nb") == .wrong(line: 1, expected: "a", actual: "", matching: 1, of: 2))
        #expect(Score.compare(actual: "", expected: "a") == .wrong(line: 1, expected: "a", actual: nil, matching: 0, of: 1))
    }

    @Test func theRetrySaysWhetherALineIsEmptyOrMissing() {
        let empty = Prompts.retry(.wrongOutput(line: 1, expected: "a", actual: "", head: ""))
        let missing = Prompts.retry(.wrongOutput(line: 2, expected: "b", actual: nil, head: "a"))
        let extra = Prompts.retry(.wrongOutput(line: 2, expected: nil, actual: "b", head: "a\nb"))
        #expect(empty.contains("(an empty line)") && !empty.contains("(nothing"))
        #expect(missing.contains("the output ended before this line"))
        #expect(extra.contains("the output should have ended before this line"))
    }

    @Test func leadingSpaceCounts() {
        #expect(Score.compare(actual: "[A]", expected: "    [A]") != .pass)
    }
}

@Suite struct FixtureTests {
    @Test func shortSamplesAreAPrefixOfTheInput() {
        for fixture in Fixture.all {
            #expect(fixture.input.hasPrefix(fixture.shortSample))
            #expect(fixture.shortSample.split(separator: "\n", omittingEmptySubsequences: false).count == fixture.sampleLines)
        }
    }

    @Test func sampleOutputsAreAPrefixOfTheExpectedText() {
        // The string table's sample output closes the table early, so only
        // its lines before the closing one are a prefix.
        for fixture in Fixture.all {
            let lines = fixture.sampleExpected.split(separator: "\n")
            let body = fixture.id == "string-table" ? lines.dropLast() : lines[...]
            #expect(fixture.expected.hasPrefix(body.joined(separator: "\n")))
        }
        #expect(Prompts.request(instruction: "do", sample: "a", isWholeText: false, sampleOutput: "b").hasSuffix("exactly:\nb"))
    }

    @Test func instructionsAgreeWithTheRequestAboutTheSample() {
        for guided in [false, true] {
            let sample = Prompts.instructions(.detailed, guided: guided, wholeText: false)
            let whole = Prompts.instructions(.detailed, guided: guided, wholeText: true)
            #expect(sample.contains("longer than the sample"))
            #expect(!whole.contains("longer than the sample") && !whole.contains("sample"))
            #expect(whole.contains("the whole text"))
        }
        #expect(!Prompts.instructions(.terse, guided: false, wholeText: true).contains("sample"))
    }

    @Test func promptsNameTheSampleHonestly() {
        #expect(Prompts.request(instruction: "do", sample: "a", isWholeText: false).contains("more lines"))
        #expect(!Prompts.request(instruction: "do", sample: "a", isWholeText: true).contains("more lines"))
    }
}
