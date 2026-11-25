import Foundation
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

@Suite struct ChatCompletionTests {
    func reply(_ content: String?, finish: String = "stop") -> Data {
        var message: [String: Any] = ["role": "assistant"]
        if let content { message["content"] = content }
        return try! JSONSerialization.data(withJSONObject: ["choices": [["message": message, "finish_reason": finish]]])
    }

    @Test func theBodyCarriesTheSettingsAndTheExtraFields() {
        let body = ChatCompletion.body(model: "m", messages: [["role": "user", "content": "hi"]], temperature: 0.2, topP: 1,
                                       maxTokens: 2048, extra: ["chat_template_kwargs": ["enable_thinking": false]])
        #expect(body["model"] as? String == "m")
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["max_tokens"] as? Int == 2048)
        #expect(body["stream"] as? Bool == false)
        #expect((body["chat_template_kwargs"] as? [String: Bool]) == ["enable_thinking": false])
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func anExtraFieldCanReplaceAStandardOne() {
        let body = ChatCompletion.body(model: "m", messages: [], temperature: 0.2, topP: 1, maxTokens: 2048, extra: ["max_tokens": 64])
        #expect(body["max_tokens"] as? Int == 64)
    }

    @Test func theContentIsReadWithoutItsThinking() {
        #expect(ChatCompletion.content(in: reply("```js\nfunction main(state) {}\n```")) == "```js\nfunction main(state) {}\n```")
        #expect(ChatCompletion.content(in: reply("<think>first this\nthen that</think>\nthe answer")) == "the answer")
        #expect(ChatCompletion.content(in: reply("<think>a</think>x<think>b</think>y")) == "xy")
        #expect(ChatCompletion.content(in: reply("<think>never closed")) == "<think>never closed")
    }

    @Test func aReplyWithoutContentIsNil() {
        #expect(ChatCompletion.content(in: reply(nil)) == nil)
        #expect(ChatCompletion.content(in: Data("not json".utf8)) == nil)
        #expect(ChatCompletion.content(in: Data(#"{"error":{"message":"no"}}"#.utf8)) == nil)
    }

    @Test func aReplyWithAnAnswerIsItsContent() {
        #expect(ChatCompletion.reply(in: reply("the answer")) == .content("the answer"))
        #expect(ChatCompletion.reply(in: reply("<think>first</think>the answer")) == .content("the answer"))
        #expect(ChatCompletion.reply(in: reply("", finish: "stop")) == .content(""), "empty, but the model chose to stop")
        #expect(ChatCompletion.reply(in: reply("half a script", finish: "length")) == .content("half a script"),
                "cut off, but with something to judge")
    }

    /// The three shapes a server gives a reply that ran out of tokens
    /// while the model was still reasoning.
    @Test func aReplyThatRanOutWhileReasoningWasCutOff() {
        #expect(ChatCompletion.reply(in: reply("", finish: "length")) == .cutOff, "empty content")
        #expect(ChatCompletion.reply(in: reply(nil, finish: "length")) == .cutOff, "no content: the reasoning has a field of its own")
        #expect(ChatCompletion.reply(in: reply("<think>still reasoning when the tokens ran", finish: "length")) == .cutOff,
                "reasoning in the content, never closed")
        #expect(ChatCompletion.reply(in: reply("<think>a</think><think>and again, unfinished", finish: "length")) == .cutOff)
    }

    @Test func anAnswerBeforeUnfinishedReasoningIsKept() {
        #expect(ChatCompletion.reply(in: reply("the answer\n<think>and then more", finish: "length")) == .content("the answer"))
    }

    @Test func unfinishedReasoningWithoutTheTokenLimitIsLeftAlone() {
        #expect(ChatCompletion.reply(in: reply("<think>never closed", finish: "stop")) == .content("<think>never closed"))
    }

    @Test func aReplyThatIsNoCompletionIsNone() {
        #expect(ChatCompletion.reply(in: reply(nil)) == .none)
        #expect(ChatCompletion.reply(in: Data("not json".utf8)) == .none)
        #expect(ChatCompletion.reply(in: Data(#"{"error":{"message":"no"}}"#.utf8)) == .none)
    }

    @Test func theReportStatesTheSettingsAsSent() {
        let plain = ChatCompletion.body(model: "m", messages: [], temperature: 0.2, topP: 1, maxTokens: 2048)
        #expect(ChatCompletion.effective(plain).maxTokens == "2048")
        #expect(ChatCompletion.effective(plain).temperature == "0.2")
        let replaced = ChatCompletion.body(model: "m", messages: [], temperature: 0.2, topP: 1, maxTokens: 2048,
                                           extra: ["max_tokens": 64, "temperature": 0.9])
        #expect(ChatCompletion.effective(replaced).maxTokens == "64", "what went out, not what was asked first")
        #expect(ChatCompletion.effective(replaced).temperature == "0.9")
        #expect(ChatCompletion.effective(replaced).topP == "1.0")
    }

    @Test func theCompletionsURLIsUnderV1Once() {
        #expect(ChatCompletion.url(base: URL(string: "http://host.example:4000")!).absoluteString == "http://host.example:4000/v1/chat/completions")
        #expect(ChatCompletion.url(base: URL(string: "http://host.example:4000/v1")!).absoluteString == "http://host.example:4000/v1/chat/completions")
        #expect(ChatCompletion.url(base: URL(string: "http://host.example:4000/v1/")!).absoluteString == "http://host.example:4000/v1/chat/completions")
        #expect(ChatCompletion.url(base: URL(string: "https://host.example/api")!).absoluteString == "https://host.example/api/v1/chat/completions")
    }
}
