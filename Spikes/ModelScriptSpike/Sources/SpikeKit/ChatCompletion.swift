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
    /// an answer and is kept.
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

    /// Some servers put the reasoning in the content, between `<think>`
    /// tags. An opening tag that never closes is left as it is.
    public static func withoutThinking(_ text: String) -> String {
        var text = text
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
