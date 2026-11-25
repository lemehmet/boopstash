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

    /// The reply stopped at the token limit with nothing in it: a model
    /// that reasons first spent the whole allowance on its reasoning.
    public static func wasCutOffEmpty(_ data: Data) -> Bool {
        content(in: data)?.isEmpty == true && finishReason(in: data) == "length"
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
