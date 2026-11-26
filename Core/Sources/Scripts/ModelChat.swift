import Foundation

// macOS only (ADR 0014): the safeguard this rests on, an app without a
// network entitlement and a separate sandboxed helper that makes the
// request, does not exist on iOS, so none of this is compiled there.
#if os(macOS)

/// BoopStash's own fixed prompt and the request text around the user's
/// instruction, examples and sample (ADR 0014). The wording is the
/// baseline the spike measured (ADR 0013, `Spikes/ModelScriptSpike`).
public enum ModelScriptPrompt {
    /// How a script is written, the script API and one example script.
    /// `wholeText` says whether the request shows all of the text or only
    /// a sample, so the instructions never contradict the request.
    public static func instructions(wholeText: Bool) -> String {
        let scope = wholeText
            ? "You are shown the whole text. Still write general rules, never a list of its values."
            : "The script runs on the whole text, which is longer than the sample you are shown, so write general rules, never the sample's values."
        return """
        You write small scripts for a text editor. A script is plain JavaScript that defines one function, main(state).
        - state.text is the text to transform, a string with lines separated by "\\n". Assign the result to state.text.
        - Use only the JavaScript language itself: strings, arrays, regular expressions. There is no require, no console, no files and no network.
        - \(scope)
        - If the text cannot be transformed, call state.postError("why") and leave state.text alone.
        Reply with the complete script in one ```js code block and nothing else.

        An example, for "trim every line and drop empty lines":
        function main(state) {
          const lines = state.text.split("\\n");
          state.text = lines.map(line => line.trim()).filter(line => line.length > 0).join("\\n");
        }
        """
    }

    /// The user's part of the request: the instruction, then the lines
    /// marked as examples, then the sample. Nothing else of the note.
    public static func request(instruction: String, examples: [ScriptExample] = [], sample: ScriptSample) -> String {
        var parts = ["Task: \(instruction)"]
        if !examples.isEmpty {
            let shown = examples.map { example in
                if let expected = example.wanted {
                    return "This line:\n\(example.text)\nmust become exactly:\n\(expected)"
                }
                return "A line the script must handle:\n\(example.text)"
            }
            parts.append("Lines of the text marked as examples:\n" + shown.joined(separator: "\n\n"))
        }
        let label = sample.isWholeText ? "The text:" : "A sample of the text (the whole text has more lines like these):"
        parts.append("\(label)\n\(sample.text)")
        return parts.joined(separator: "\n\n")
    }
}

/// How much of the text fits a request, from the context length.
public enum ModelSampleBudget {
    /// Tokens kept free for what cannot be counted here: the chat
    /// template around the messages, and a tokenizer less generous than
    /// the estimate.
    public static let margin = 512

    /// An estimate of `text`'s tokens that errs high, also for the text
    /// the workbench is mostly given: one token for every three letters
    /// or spaces, and a whole token for each digit and each punctuation
    /// mark or symbol, since tokenizers split numbers digit by digit or in
    /// short groups. A character outside ASCII counts as two.
    public static func tokens(in text: some StringProtocol) -> Int {
        var wordBytes = 0
        var singles = 0
        var wide = 0
        for scalar in text.unicodeScalars {
            if !scalar.isASCII {
                wide += 1
            } else if (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
                        || scalar == " " || scalar == "\t" {
                wordBytes += 1
            } else {
                singles += 1
            }
        }
        return (wordBytes + 2) / 3 + singles + 2 * wide
    }

    /// Tokens left for the sample: the context length less the reply
    /// limit, the margin, the fixed prompt, the instruction and the
    /// examples. Never negative.
    public static func sampleTokens(context: Int, reply: Int, instruction: String, examples: [ScriptExample]) -> Int {
        let empty = ScriptSample(text: "", isWholeText: false, totalLines: 0)
        let fixed = tokens(in: ModelScriptPrompt.instructions(wholeText: false))
        let request = tokens(in: ModelScriptPrompt.request(instruction: instruction, examples: examples, sample: empty))
        return max(0, context - reply - margin - fixed - request)
    }
}

/// An OpenAI-compatible chat completions exchange: building the request
/// body and reading the reply. Pure; ported from the spike's
/// `ChatCompletion`, which measured it against real servers.
public enum ModelChat {
    public struct Message: Sendable, Hashable {
        public var role: String
        public var content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// The two messages of a request: BoopStash's fixed prompt, and the
    /// user's instruction, examples and sample.
    public static func messages(for request: ScriptGenerationRequest) -> [Message] {
        [
            Message(role: "system", content: ModelScriptPrompt.instructions(wholeText: request.sample.isWholeText)),
            Message(role: "user", content: ModelScriptPrompt.request(
                instruction: request.instruction, examples: request.examples, sample: request.sample)),
        ]
    }

    /// The request body: the model, the messages, the generation settings
    /// in range, `stream` off, and the extra request fields beside them.
    /// Extra fields that are not a JSON object, or that name a field the
    /// request sets itself, are refused: no body is made with them, so
    /// what the interface shows as sent is what is sent.
    public static func body(model: String, messages: [Message], settings: ModelGenerationSettings)
        -> Result<Data, ModelExtraFields.Refusal> {
        let extra: [String: Any]
        switch ModelExtraFields.parse(settings.extraFields) {
        case .success(let object): extra = object
        case .failure(let refusal): return .failure(refusal)
        }
        let settled = settings.clamped().settings
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": settled.temperature,
            "top_p": settled.topP,
            "max_tokens": settled.maxReplyTokens,
            "stream": false,
        ]
        for (key, value) in extra { body[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            return .failure(ModelExtraFields.Refusal(reason: "The request could not be written as JSON."))
        }
        return .success(data)
    }

    /// What a reply amounts to.
    public enum Reply: Sendable, Equatable {
        /// Text to look for a script in; `limited` when the reply stopped
        /// at the token limit, so the text may end mid-script.
        case content(String, limited: Bool)
        /// The reply stopped at the token limit before any answer: a model
        /// that reasons first spent the whole allowance on its reasoning.
        case cutOff
        /// No usable reply: not the shape of a completion, or no content
        /// and no token limit to blame.
        case none
    }

    /// The reply, with a cut-off told apart from an answer. At the token
    /// limit a reply has no answer in three shapes, depending on the
    /// server: empty content, no content at all (the reasoning went to a
    /// field of its own), or content that is reasoning still open, a
    /// `<think>` without its end. Whatever stands before that open tag is
    /// an answer and is kept. A `<think>` inside a code block is the
    /// script's own text, not reasoning (#281).
    public static func reply(in data: Data) -> Reply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [Any])?.first as? [String: Any]
        else { return .none }
        let limited = choice["finish_reason"] as? String == "length"
        guard let raw = (choice["message"] as? [String: Any])?["content"] as? String else {
            return limited ? .cutOff : .none
        }
        let answer = answer(in: raw)
        var text = answer.text
        if limited, let open = answer.openReasoning { text = String(text[..<open]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if limited, text.isEmpty { return .cutOff }
        return .content(text, limited: limited)
    }

    /// Some servers put the reasoning in the content, between `<think>`
    /// tags. Some return only the closing tag, `reasoning…</think>answer`,
    /// because the chat template put the opening one in the prompt: then
    /// everything up to that unmatched closing tag is reasoning too. An
    /// opening tag that never closes is left as it is.
    ///
    /// The tags count only outside ``` code blocks (#281): a script that
    /// mentions them, as one asked to strip them does, is left whole, and
    /// so is one followed by a sentence that names the closing tag.
    public static func withoutThinking(_ text: String) -> String {
        answer(in: text).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `reply` without its reasoning, and where in it a `<think>` that
    /// never closes begins, if one does outside a code block.
    ///
    /// Reads the reply once, from its start. A block begins and ends at
    /// a line that starts with ```, as `ModelScriptReply` reads them, and
    /// nothing inside one is a tag. Outside blocks, a `<think>` goes
    /// with everything up to the next `</think>` that is outside a block
    /// too (reasoning that drafts a block takes the block with it), and
    /// a `</think>` with no opening tag takes everything before it,
    /// unless a block stands before it: then it takes nothing. It may
    /// be prose about the script ("this keeps what follows `</think>`")
    /// or the end of reasoning that drafted a block, and keeping the
    /// block is right for both, as the script is the last block that
    /// defines `main` (`ModelScriptReply.extract`).
    ///
    /// Three shapes cannot be told from what they look like, and the
    /// model is asked to answer in one block, which avoids all three:
    /// - reasoning that opens a block and never ends it is read as a
    ///   script that mentions the tags;
    /// - reasoning that drafts a block, ends with a closing tag alone
    ///   and is followed by an answer with no block keeps the draft;
    /// - prose that names `<think>` before the script's block and
    ///   `</think>` after it is read as reasoning that drafted a block,
    ///   and the script goes with it.
    static func answer(in reply: String) -> (text: String, openReasoning: String.Index?) {
        var kept = Kept()
        var rest = reply[...]
        var opening = TagSearch("<think>")
        var closing = TagSearch("</think>")
        var fences = FenceSearch()
        while !rest.isEmpty {
            let fence = fences.next(in: rest, atLineStart: kept.atLineStart)
            let open = opening.next(in: rest)
            let close = closing.next(in: rest)
            guard let first = [fence, open, close].compactMap({ $0?.lowerBound }).min() else { break }
            if let fence, fence.lowerBound == first {
                // A block: kept as it is, to the line that ends it, or to
                // the end of a reply that never ends it.
                let end = FenceSearch.afterLineBreak(in: rest[fence.upperBound...])?.upperBound ?? rest.endIndex
                kept.append(rest[..<end])
                kept.hasBlock = true
                rest = rest[end...]
            } else if let open, open.lowerBound == first {
                // Its closing tag is the next one outside a block: the
                // reasoning may draft blocks of its own.
                var inner = rest[open.upperBound...]
                var end: Range<String.Index>?
                while end == nil, let close = closing.next(in: inner) {
                    guard let block = fences.next(in: inner, atLineStart: false), block.lowerBound < close.lowerBound else {
                        end = close
                        break
                    }
                    guard let blockEnd = FenceSearch.afterLineBreak(in: inner[block.upperBound...]) else { break }
                    inner = inner[blockEnd.upperBound...]
                }
                guard let end else {
                    // Reasoning still open: left as it is, and said.
                    kept.append(rest[..<open.lowerBound])
                    let at = kept.text.endIndex
                    return (kept.text + rest[open.lowerBound...], at)
                }
                kept.append(rest[..<open.lowerBound])
                rest = rest[end.upperBound...]
            } else if let close {
                if kept.hasBlock {
                    // A block stands before it: the block stays, whether
                    // the tag is named in what is said about the script
                    // or ends reasoning that drafted it.
                    kept.append(rest[..<close.upperBound])
                } else {
                    // A closing tag alone: all before it was reasoning.
                    kept = Kept()
                }
                rest = rest[close.upperBound...]
            }
        }
        return (kept.text + rest, nil)
    }

    /// What of the reply is kept so far, whether a block is in it, and
    /// whether what comes next starts a line of it, with at most blanks
    /// before it: the place where ``` opens a block. That is kept up as
    /// text is added, from the added text alone, so that a reply of many
    /// tags with blanks between them is not read again for each (#281).
    private struct Kept {
        private(set) var text = ""
        private(set) var atLineStart = true
        var hasBlock = false

        mutating func append(_ piece: Substring) {
            text += piece
            for scalar in piece.unicodeScalars.reversed() {
                if FenceSearch.isLineBreak(scalar) {
                    atLineStart = true
                    return
                }
                if !FenceSearch.isBlank(scalar) {
                    atLineStart = false
                    return
                }
            }
        }
    }

    /// Finds a tag from where the reading stands, remembering where it
    /// last found it, or that there is none left, so that reading a long
    /// reply with many blocks and tags searches each part of it once.
    private struct TagSearch {
        let tag: String
        private var found: Range<String.Index>?
        private var exhausted = false

        init(_ tag: String) {
            self.tag = tag
        }

        mutating func next(in rest: Substring) -> Range<String.Index>? {
            if exhausted { return nil }
            if let found, found.lowerBound >= rest.startIndex { return found }
            found = rest.range(of: tag)
            exhausted = found == nil
            return found
        }
    }

    /// Finds the next ``` that starts a line, after blanks at most, and
    /// remembers it as `TagSearch` does.
    private struct FenceSearch {
        private var found: Range<String.Index>?
        private var exhausted = false

        /// The start of `rest` starts a line only if `atLineStart`: what
        /// was kept before it may have put text on its line, or taken it
        /// away.
        mutating func next(in rest: Substring, atLineStart: Bool) -> Range<String.Index>? {
            if atLineStart, let leading = Self.leading(in: rest) { return leading }
            if exhausted { return nil }
            if let found, found.lowerBound >= rest.startIndex { return found }
            found = Self.afterLineBreak(in: rest)
            exhausted = found == nil
            return found
        }

        /// ``` at the start of `text`, after blanks at most.
        static func leading(in text: Substring) -> Range<String.Index>? {
            let scalars = text.unicodeScalars
            var index = scalars.startIndex
            while index < scalars.endIndex, isBlank(scalars[index]) { index = scalars.index(after: index) }
            guard scalars[index...].starts(with: marker) else { return nil }
            return index..<scalars.index(index, offsetBy: 3)
        }

        /// The first ``` in `text` that follows a line break and blanks
        /// at most. A carriage return counts, alone or before a line feed.
        static func afterLineBreak(in text: Substring) -> Range<String.Index>? {
            let scalars = text.unicodeScalars
            var index = scalars.startIndex
            var lineStart = false
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if isLineBreak(scalar) {
                    lineStart = true
                } else if lineStart, scalar == "`", scalars[index...].starts(with: marker) {
                    return index..<scalars.index(index, offsetBy: 3)
                } else if !isBlank(scalar) {
                    lineStart = false
                }
                index = scalars.index(after: index)
            }
            return nil
        }

        static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "\n" || scalar == "\r"
        }

        /// What may stand before ``` on its line: what
        /// `ModelScriptReply.fencedBlocks` trims from a line, a tab or
        /// any space there is, a no-break space included.
        static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || (scalar.value >= 0x80 && scalar.properties.generalCategory == .spaceSeparator)
        }

        private static let marker: [Unicode.Scalar] = ["`", "`", "`"]
    }

    /// The message of an error body, in the shapes servers use:
    /// `{"error":{"message":…}}`, `{"error":…}`, `{"message":…}` and
    /// `{"detail":…}`. Nil for anything else, an HTML page included.
    /// Shortened to a few lines' worth.
    public static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let found = (object["error"] as? [String: Any])?["message"] as? String
            ?? object["error"] as? String
            ?? object["message"] as? String
            ?? object["detail"] as? String
        guard let message = found?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
        return message.count > 300 ? String(message.prefix(300)) + "…" : message
    }

    /// What the workbench gets from the helper's answer to a chat request:
    /// the script, or which way it failed. A reply stopped at the token
    /// limit counts as a script only when its code block was closed; cut
    /// off before that, it is `.cutOff`, never half a script.
    public static func outcome(of response: ModelServiceResponse, host: String, timeLimit: Double, apiKey: String? = nil)
        -> Result<String, ScriptGenerationFailure> {
        if let failure = response.failure {
            if failure == .cancelled { return .failure(.cancelled) }
            let message = failure.message(host: host, timeLimit: timeLimit)
            if case .unreachable = failure { return .failure(.unavailable(message)) }
            return .failure(.failed(message))
        }
        guard let status = response.status, (200..<300).contains(status) else {
            return .failure(.failed(ModelServiceResponse.statusMessage(response, host: host, apiKey: apiKey)))
        }
        switch reply(in: response.body) {
        case .none:
            return .failure(.failed("\(host) answered, but not with a chat completion. Check the base URL in Settings ▸ Model."))
        case .cutOff:
            return .failure(.cutOff)
        case .content(let text, let limited):
            if let script = ModelScriptReply.extract(text, closedBlocksOnly: limited) { return .success(script) }
            return .failure(limited ? .cutOff : .noScript)
        }
    }
}

/// Finding the script in a model's reply. The model is asked for one code
/// block; it also answers with prose around the block, several blocks, or
/// bare code. Ported from the spike's `ScriptReply`.
public enum ModelScriptReply {
    /// The script, or nil when the reply holds nothing that defines `main`.
    /// A fenced block that defines `main` wins (the last one, as a model
    /// that corrects itself puts the fix last); otherwise the whole reply,
    /// when it is bare code. With `closedBlocksOnly`, for a reply that
    /// stopped at the token limit, only a block that was closed counts:
    /// an open block and bare code may end mid-script.
    public static func extract(_ reply: String, closedBlocksOnly: Bool = false) -> String? {
        let (blocks, lastIsOpen) = fencedBlocks(reply)
        let usable = closedBlocksOnly && lastIsOpen ? Array(blocks.dropLast()) : blocks
        if let block = usable.last(where: definesMain) { return block }
        guard !closedBlocksOnly else { return nil }
        let bare = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return blocks.isEmpty && definesMain(bare) ? bare : nil
    }

    /// The bodies of the reply's ``` blocks, without the fences and the
    /// language tag. A last block that was never closed counts, and is
    /// said to be open.
    static func fencedBlocks(_ reply: String) -> (blocks: [String], lastIsOpen: Bool) {
        var blocks: [String] = []
        var current: [Substring]?
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if isFence {
                if let body = current {
                    blocks.append(body.joined(separator: "\n"))
                    current = nil
                } else {
                    current = []
                }
            } else {
                current?.append(line)
            }
        }
        if let open = current {
            let body = open.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                blocks.append(body)
                return (blocks, true)
            }
        }
        return (blocks, false)
    }

    /// Whether the code defines `main` where the script service looks for
    /// it, as a property of the global object: a function declaration, or a
    /// function assigned to `main` with `var` or with no keyword. `const
    /// main = …` and `let main = …` do not count: they bind a name the
    /// service cannot see.
    public static func definesMain(_ code: String) -> Bool {
        if code.range(of: #"function\s*\*?\s+main\s*\("#, options: .regularExpression) != nil { return true }
        guard let assignment = try? NSRegularExpression(
            pattern: #"(?:\b(const|let|var)\s+)?(?<![\w$.])main\s*=\s*(?:async\s+)?(?:function\b|\(|[A-Za-z_$][\w$]*\s*=>)"#)
        else { return false }
        let whole = NSRange(code.startIndex..., in: code)
        return assignment.matches(in: code, range: whole).contains { match in
            guard let keyword = Range(match.range(at: 1), in: code) else { return true }
            return code[keyword] == "var"
        }
    }
}

/// The service's own list of models (`GET <base>/v1/models`).
public enum ModelList {
    /// The model names in OpenAI's shape, `{"data":[{"id":…}]}`, in the
    /// service's order and without repeats; other fields are ignored.
    /// Nil when the body is not that shape.
    public static func parse(_ data: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [Any]
        else { return nil }
        var seen: Set<String> = []
        var names: [String] = []
        for entry in entries {
            guard let id = (entry as? [String: Any])?["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
            names.append(id)
        }
        return names
    }

    /// The list from the helper's answer, or why there is none.
    public static func outcome(of response: ModelServiceResponse, host: String, timeLimit: Double, apiKey: String? = nil)
        -> Result<[String], ModelListFailure> {
        if let failure = response.failure {
            return .failure(ModelListFailure(reason: failure.message(host: host, timeLimit: timeLimit)))
        }
        guard let status = response.status, (200..<300).contains(status) else {
            return .failure(ModelListFailure(reason: ModelServiceResponse.statusMessage(response, host: host, apiKey: apiKey)))
        }
        guard let names = parse(response.body) else {
            return .failure(ModelListFailure(reason: "\(host) answered, but not with a list of models."))
        }
        return .success(names)
    }

    /// One row of the model field's list.
    public struct Option: Sendable, Hashable, Identifiable {
        public var name: String
        /// The service lists it now.
        public var isOffered: Bool

        public var id: String { name }

        /// The row's text: a model the service stopped listing says so.
        public var title: String { isOffered ? name : "\(name) (not offered by the service)" }
    }

    /// The rows for a list the service gave and the model chosen before:
    /// a chosen model the service no longer lists stays, first, marked as
    /// not offered.
    public static func options(listed: [String], chosen: String) -> [Option] {
        let chosen = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = listed.map { Option(name: $0, isOffered: true) }
        if !chosen.isEmpty, !listed.contains(chosen) {
            options.insert(Option(name: chosen, isOffered: false), at: 0)
        }
        return options
    }
}

public struct ModelListFailure: Error, Sendable, Hashable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// What the app hands the model helper for one request, and all of it
/// (ADR 0014): which call, the endpoint's address, the user's key if they
/// set one, the request body, and the limits. The helper adds nothing
/// from anywhere else.
public struct ModelServiceRequest: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Call: String, Sendable, Codable {
        /// `GET <base>/v1/models`: carries the key and nothing else.
        case models
        /// `POST <base>/v1/chat/completions` with `body`.
        case chat
    }

    public var call: Call
    public var baseURL: String
    public var apiKey: String?
    /// The chat request's JSON body; nil for the model list.
    public var body: Data?
    /// Seconds the whole request may take.
    public var timeLimit: Double

    public init(call: Call, baseURL: String, apiKey: String?, body: Data?, timeLimit: Double) {
        self.call = call
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.body = body
        self.timeLimit = timeLimit
    }

    /// Never the key, the address or the body: a request that ends up in
    /// a log or an error says only which call it was.
    public var description: String { "ModelServiceRequest(\(call.rawValue))" }
    public var debugDescription: String { description }

    /// The largest reply the helper reads; a script and a model list are
    /// far smaller.
    public static let maxReplyBytes = 4 * 1024 * 1024

    /// The HTTP request the helper makes, or why it makes none. The
    /// address is checked again here, by the same rule as in Settings.
    /// The headers are fixed and say nothing of the user or the device:
    /// no cookies, the app's name without a version, one language.
    public func urlRequest() -> Result<URLRequest, ModelServiceResponse.Failure> {
        let address: ModelEndpointAddress
        switch ModelEndpointAddress.parse(baseURL) {
        case .success(let parsed): address = parsed
        case .failure(let problem): return .failure(.refused(problem.message))
        }
        var request: URLRequest
        switch call {
        case .models:
            guard body == nil else { return .failure(.refused("A model list request carries no body.")) }
            request = URLRequest(url: address.modelsURL)
            request.httpMethod = "GET"
        case .chat:
            guard let body else { return .failure(.refused("A chat request needs a body.")) }
            request = URLRequest(url: address.chatURL)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BoopStash", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = Self.limit(timeLimit)
        return .success(request)
    }

    /// The time limit in the settings' range, whatever was sent.
    public static func limit(_ timeLimit: Double) -> Double {
        let range = ModelGenerationSettings.timeLimitRange
        guard timeLimit.isFinite else { return range.upperBound }
        return min(max(timeLimit, range.lowerBound), range.upperBound)
    }
}

/// The helper's answer: the HTTP status and body, or how the request
/// failed before there was one.
public struct ModelServiceResponse: Sendable, Hashable, Codable {
    public enum Failure: Error, Sendable, Hashable, Codable {
        /// No connection: the host is down, unknown or refused it.
        case unreachable(String)
        case timedOut
        /// The TLS certificate was not trusted.
        case certificate(String)
        /// The reply was larger than `maxReplyBytes`.
        case tooLarge
        /// The service answered with a redirect, which is not followed:
        /// the text and the key go to the host the user typed and to no
        /// other.
        case redirected
        /// The helper made no request, and why.
        case refused(String)
        case cancelled
        case failed(String)

        public func message(host: String, timeLimit: Double) -> String {
            switch self {
            case .unreachable(let detail): "The model at \(host) could not be reached: \(detail)"
            case .timedOut:
                "The model at \(host) did not answer within \(Int(ModelServiceRequest.limit(timeLimit))) seconds. It may still be loading; try again, or raise the time limit in Settings ▸ Model."
            case .certificate(let detail): "The connection to \(host) is not trusted, so nothing was sent: \(detail)"
            case .tooLarge: "The reply from \(host) was larger than \(ModelServiceRequest.maxReplyBytes / 1024 / 1024) MB and was dropped."
            case .redirected:
                "\(host) answered with a redirect, which BoopStash does not follow. Enter the address it points to as the base URL."
            case .refused(let reason): reason
            case .cancelled: "The request was cancelled."
            case .failed(let detail): "The request to \(host) failed: \(detail)"
            }
        }
    }

    public var status: Int?
    public var body: Data
    public var failure: Failure?

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public init(failure: Failure) {
        body = Data()
        self.failure = failure
    }

    /// What to say of a status that is not a success: the status, and the
    /// service's own message when its body has one. The key never shows,
    /// even if the service echoes it.
    public static func statusMessage(_ response: ModelServiceResponse, host: String, apiKey: String?) -> String {
        let status = response.status.map { "HTTP \($0)" } ?? "no status"
        var said = ModelChat.errorMessage(in: response.body)
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            said = said?.replacingOccurrences(of: key, with: "(the API key)")
        }
        let hint = response.status == 401 || response.status == 403 ? " Check the API key in Settings ▸ Model." : ""
        guard let said else { return "\(host) answered with an error (\(status)).\(hint)" }
        return "\(host) answered with an error (\(status)): \(said)\(hint)"
    }
}

/// The workbench's generator over a model endpoint the user configured
/// (ADR 0014). Pure: the settings, the key and the helper are handed in,
/// so what a request holds is tested without a server.
///
/// Asking whether it is available reads the settings and sends nothing;
/// only `generate` and `models` reach the helper, and with nothing
/// configured neither is ever called.
public struct ModelEndpointGenerator: ScriptGenerator {
    public typealias Transport = @Sendable (ModelServiceRequest) async -> ModelServiceResponse

    private let settings: @Sendable () async -> ModelEndpointSettings
    private let apiKey: @Sendable (ModelEndpointAddress) async throws -> String?
    private let transport: Transport

    /// - Parameters:
    ///   - settings: what Settings ▸ Model holds now.
    ///   - apiKey: the key the Keychain holds for the address it is
    ///     given, nil when none is set. The address is the one the
    ///     request goes to, so a key is never read for one endpoint and
    ///     sent to another.
    ///   - transport: the model helper.
    public init(settings: @escaping @Sendable () async -> ModelEndpointSettings,
                apiKey: @escaping @Sendable (ModelEndpointAddress) async throws -> String?,
                transport: @escaping Transport) {
        self.settings = settings
        self.apiKey = apiKey
        self.transport = transport
    }

    public func availability() async -> ScriptGeneratorAvailability {
        Self.availability(for: await settings())
    }

    public static func availability(for settings: ModelEndpointSettings) -> ScriptGeneratorAvailability {
        switch settings.state {
        case .off: return .notConfigured
        case .incomplete(let reason): return .unavailable(reason: reason)
        case .ready(let address):
            let generation = settings.generation.clamped().settings
            return .available(ScriptGeneratorDestination(
                summary: "the model at \(address.host)", host: address.host, locality: address.locality,
                allowance: .tokens(context: generation.contextLength, reply: generation.maxReplyTokens)))
        }
    }

    /// What `generate` answers when the settings are no longer the ones
    /// the workbench showed.
    public static let settingsChanged = "The model settings changed since this sheet showed where the text goes, so nothing was sent. Choose Check Again, look at the destination, then Generate."

    /// The settings are read once, and that one reading decides where the
    /// request goes, which key goes with it and what it carries. When the
    /// request names the destination the workbench showed, a reading that
    /// no longer gives that destination sends nothing: the text goes
    /// where the mark said, or nowhere.
    public func generate(_ request: ScriptGenerationRequest) async -> Result<String, ScriptGenerationFailure> {
        let settings = await settings()
        guard case .ready(let address) = settings.state else {
            if case .incomplete(let reason) = settings.state { return .failure(.unavailable(reason)) }
            return .failure(.unavailable("No model is set up in Settings ▸ Model."))
        }
        if let shown = request.destination, Self.availability(for: settings) != .available(shown) {
            return .failure(.unavailable(Self.settingsChanged))
        }
        let key: String?
        do { key = try await apiKey(address) } catch {
            return .failure(.unavailable("The API key could not be read from the Keychain, so no request was made."))
        }
        let body: Data
        switch ModelChat.body(model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines),
                              messages: ModelChat.messages(for: request), settings: settings.generation) {
        case .success(let data): body = data
        case .failure(let refusal): return .failure(.unavailable(refusal.reason))
        }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let timeLimit = settings.generation.clamped().settings.timeLimit
        let response = await transport(ModelServiceRequest(
            call: .chat, baseURL: address.url.absoluteString, apiKey: key, body: body, timeLimit: timeLimit))
        guard !Task.isCancelled else { return .failure(.cancelled) }
        return ModelChat.outcome(of: response, host: address.host, timeLimit: timeLimit, apiKey: key)
    }

    /// Seconds the model list may take: it is a small answer, and
    /// Settings waits on it.
    public static let listTimeLimit = 15.0

    /// The service's model list, for Settings. Sends the key and nothing
    /// else; the key is read for the address the request goes to.
    public static func models(settings: ModelEndpointSettings,
                              apiKey: @Sendable (ModelEndpointAddress) async throws -> String?,
                              transport: Transport) async -> Result<[String], ModelListFailure> {
        let address: ModelEndpointAddress
        switch ModelEndpointAddress.parse(settings.baseURL) {
        case .success(let parsed): address = parsed
        case .failure(let problem): return .failure(ModelListFailure(reason: problem.message))
        }
        let key: String?
        do { key = try await apiKey(address) } catch {
            return .failure(ModelListFailure(reason: "The API key could not be read from the Keychain, so no request was made."))
        }
        guard !Task.isCancelled else { return .failure(ModelListFailure(reason: "The request was cancelled.")) }
        let response = await transport(ModelServiceRequest(
            call: .models, baseURL: address.url.absoluteString, apiKey: key, body: nil, timeLimit: listTimeLimit))
        return ModelList.outcome(of: response, host: address.host, timeLimit: listTimeLimit, apiKey: key)
    }
}

extension ModelServiceResponse.Failure {
    /// What a failed load amounts to, from its `NSURLErrorDomain` code and
    /// the system's description of it.
    public init(urlErrorCode code: Int, description: String) {
        switch code {
        case NSURLErrorCancelled:
            self = .cancelled
        case NSURLErrorTimedOut:
            self = .timedOut
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet:
            self = .unreachable(description)
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            self = .certificate(description)
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            self = .refused("macOS allows plain http:// for local addresses only. Use https:// for this host.")
        case NSURLErrorDataLengthExceedsMaximum:
            self = .tooLarge
        default:
            self = .failed(description)
        }
    }
}

extension ModelEndpointAddress {
    /// The name the API key is kept under in the Keychain: the scheme,
    /// host and port, so a key entered for one endpoint is never read for
    /// another. The path is not part of it.
    public var keyAccount: String {
        "\(url.scheme?.lowercased() ?? "https")://\(host.lowercased())"
    }
}

extension ModelEndpointGenerator {
    /// What Settings ▸ Model ▸ Test asks the model: the same request as
    /// Generate, with an instruction and a sample of BoopStash's own in
    /// place of the user's, so a test sends none of their text.
    public static let testRequest = ScriptGenerationRequest(
        instruction: "trim every line",
        sample: ScriptSample(text: "  alpha  \n beta", isWholeText: true, totalLines: 2))

    /// What Test says of the answer.
    public static func testVerdict(_ result: Result<String, ScriptGenerationFailure>) -> (passed: Bool, text: String) {
        switch result {
        case .success: (true, "The model answered with a script.")
        case .failure(let failure): (false, failure.message ?? "The test was cancelled.")
        }
    }
}
#endif
