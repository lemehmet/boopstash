import Foundation
import SpikeKit

/// A model behind an OpenAI-compatible chat completions API: what
/// llama.cpp, llama-swap, Ollama, LM Studio, vLLM and MLX servers speak.
/// For measuring a model the user runs themselves with the same fixtures
/// and scoring as the on-device one (ADR 0013's bar).
///
/// Where the endpoint is and its key are the caller's: the URL comes from
/// the command line and the key from the environment, and neither is
/// written to the report.
struct Endpoint {
    var base: URL
    var model: String
    var key: String?
    var temperature: Double
    var topP: Double
    var maxTokens: Int
    var timeout: TimeInterval
    /// More fields for the request body, as the server at hand wants them:
    /// how a model's reasoning is switched off differs from one server to
    /// the next (`chat_template_kwargs` for llama.cpp, `think` for Ollama,
    /// `reasoning_effort` elsewhere).
    var extraBody: [String: Any] = [:]

    var completions: URL { ChatCompletion.url(base: base) }
}

enum EndpointError: Error, CustomStringConvertible {
    case http(Int, String)
    case noContent
    /// The reply stopped at the token limit with nothing in it: a model
    /// that reasons first spent the whole allowance on its reasoning.
    case cutOff
    case transport(String)

    var description: String {
        switch self {
        case .http(let status, let body): "http \(status): \(body.prefix(120))"
        case .noContent: "no content in the reply"
        case .cutOff: "the reply was cut off at the token limit before any answer"
        case .transport(let why): "transport: \(why)"
        }
    }
}

/// One conversation: the instructions as the system message, then each
/// request and reply in turn, so a retry sees what came before, as it does
/// in an on-device session.
final class EndpointChat {
    let endpoint: Endpoint
    private var messages: [[String: String]]

    init(endpoint: Endpoint, variation: Variation) {
        self.endpoint = endpoint
        messages = [["role": "system",
                     "content": Prompts.instructions(variation.wording, guided: false, wholeText: variation.fullSample)]]
    }

    func ask(_ prompt: String) async throws -> String {
        messages.append(["role": "user", "content": prompt])
        var request = URLRequest(url: endpoint.completions, timeoutInterval: endpoint.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = endpoint.key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let body = ChatCompletion.body(model: endpoint.model, messages: messages, temperature: endpoint.temperature,
                                       topP: endpoint.topP, maxTokens: endpoint.maxTokens, extra: endpoint.extraBody)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EndpointError.transport((error as NSError).localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw EndpointError.http(status, String(decoding: data, as: UTF8.self))
        }
        let reply: String
        switch ChatCompletion.reply(in: data) {
        case .content(let text): reply = text
        case .cutOff: throw EndpointError.cutOff
        case .none: throw EndpointError.noContent
        }
        messages.append(["role": "assistant", "content": reply])
        return reply
    }

    /// The error in a few words, for the report.
    static func name(of error: Error) -> String {
        if let error = error as? EndpointError {
            switch error {
            case .http(let status, _): return "http \(status)"
            case .noContent: return "no content"
            case .cutOff: return "cut off at the token limit"
            case .transport(let why): return why.contains("timed out") ? "request timed out" : "transport error"
            }
        }
        return ModelChat.name(of: error)
    }
}
