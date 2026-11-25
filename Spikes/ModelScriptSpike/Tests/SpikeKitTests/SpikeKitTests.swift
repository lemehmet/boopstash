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

    @Test func recognisesWaysToDefineMain() {
        #expect(ScriptReply.definesMain("const main = function (state) {}"))
        #expect(ScriptReply.definesMain("let main = state => {}"))
        #expect(ScriptReply.definesMain("var main = async (state) => {}"))
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
        #expect(Score.compare(actual: "a", expected: "a\nb") == .wrong(line: 2, expected: "b", actual: "", matching: 1, of: 2))
        #expect(Score.compare(actual: "a\nb", expected: "a") == .wrong(line: 2, expected: "", actual: "b", matching: 1, of: 1))
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

    @Test func promptsNameTheSampleHonestly() {
        #expect(Prompts.request(instruction: "do", sample: "a", isWholeText: false).contains("more lines"))
        #expect(!Prompts.request(instruction: "do", sample: "a", isWholeText: true).contains("more lines"))
    }
}
