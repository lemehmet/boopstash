import Foundation

/// The parts of an OpenAI-compatible chat completions exchange the spike
/// needs: building the request body and reading the reply. Pure, so they
/// are tested without a server.
public enum ChatCompletion {
    /// The request body: the standard fields, then `extra` merged over
    /// them, so a server-specific field can also replace a standard one.
    public static func body(model: String, messages: [[String: String]], temperature: Double, topP: Double,
                            maxTokens: Int, extra: [String: Any] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "top_p": topP,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        for (key, value) in extra { body[key] = value }
        return body
    }

    /// `choices[0].message.content` without a reasoning model's thinking,
    /// or nil when the reply has no such field.
    public static func content(in data: Data) -> String? {
        guard let message = firstChoice(in: data)?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { return nil }
        return withoutThinking(content)
    }

    /// `choices[0].finish_reason`: `length` when the reply stopped at the
    /// token limit.
    public static func finishReason(in data: Data) -> String? {
        firstChoice(in: data)?["finish_reason"] as? String
    }

    /// What a reply amounts to.
    public enum Reply: Equatable {
        /// Text to look for a script in.
        case content(String)
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
    /// an answer and is kept. Reasoning that closed with a lone `</think>`
    /// and had nothing after it is empty content, and cut off too.
    ///
    /// One shape cannot be told: when the opening tag was in the prompt
    /// and the limit fell inside the reasoning, the content is reasoning
    /// with no tag at all, which reads like any other text. It is returned
    /// as content and judged as it stands.
    public static func reply(in data: Data) -> Reply {
        guard let choice = firstChoice(in: data) else { return .none }
        let limited = choice["finish_reason"] as? String == "length"
        guard let raw = (choice["message"] as? [String: Any])?["content"] as? String else {
            return limited ? .cutOff : .none
        }
        var text = withoutThinking(raw)
        if limited, let open = text.range(of: "<think>") {
            text = String(text[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if limited, text.isEmpty { return .cutOff }
        return .content(text)
    }

    /// The fields of a request body that the report states, as they are
    /// after the extra fields were merged over them.
    public static func effective(_ body: [String: Any]) -> (temperature: String, topP: String, maxTokens: String) {
        func text(_ key: String) -> String { body[key].map { "\($0)" } ?? "unset" }
        return (text("temperature"), text("top_p"), text("max_tokens"))
    }

    /// The request fields an extra field may not replace. `model` would
    /// make the report name a model that was not the one asked; `messages`
    /// would replace the prompt being measured; `stream` would change the
    /// reply into a shape that is not read here.
    public static let reservedFields = ["messages", "model", "stream"]

    /// The reserved fields among the extra ones, sorted.
    public static func refusedExtraFields(in extra: [String: Any]) -> [String] {
        reservedFields.filter { extra[$0] != nil }
    }

    /// The report's words for an endpoint's generation settings, as they
    /// are sent: an extra request field may replace a standard one, and
    /// the report states what went out. The extra fields are written as
    /// given, values and all, so that a run can be repeated; the README
    /// and the help say so, as a credential does not belong there.
    public static func settingsLine(temperature: Double, topP: Double, maxTokens: Int, timeout: TimeInterval,
                                    extra: [String: Any]) -> String {
        let sent = effective(body(model: "", messages: [], temperature: temperature, topP: topP, maxTokens: maxTokens, extra: extra))
        let seconds = timeout == timeout.rounded() && abs(timeout) < 1e9 ? "\(Int(timeout))" : "\(timeout)"
        var text = "temperature \(sent.temperature), top-p \(sent.topP), replies capped at \(sent.maxTokens) tokens"
            + ", each request limited to \(seconds) s in total"
        if !extra.isEmpty {
            let json = (try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            text += ", extra request fields as given \(json)"
        }
        return text
    }

    /// Some servers put the reasoning in the content, between `<think>`
    /// tags. Some chat templates put the opening tag in the prompt, so
    /// the content is the reasoning, a lone `</think>`, then the answer:
    /// a closing tag with no opening one before it ends the reasoning,
    /// and everything up to it goes. An opening tag that never closes is
    /// left as it is.
    public static func withoutThinking(_ text: String) -> String {
        var text = text
        if let close = text.range(of: "</think>"), text.range(of: "<think>", range: text.startIndex..<close.lowerBound) == nil {
            text.removeSubrange(text.startIndex..<close.upperBound)
        }
        while let open = text.range(of: "<think>"),
              let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An endpoint's base is an http or https URL with a host. A bare
    /// `host:port` parses as a URL whose scheme is the host, and is not one.
    public static func isEndpoint(_ base: URL) -> Bool {
        guard let scheme = base.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(base.host ?? "").isEmpty
    }

    /// `<base>/v1/chat/completions`, also when the base already ends in `/v1`.
    public static func url(base: URL) -> URL {
        let trimmed = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
        let root = trimmed.hasSuffix("/v1") ? base : base.appendingPathComponent("v1")
        return root.appendingPathComponent("chat/completions")
    }

    private static func firstChoice(in data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]]
        else { return nil }
        return choices.first
    }
}
