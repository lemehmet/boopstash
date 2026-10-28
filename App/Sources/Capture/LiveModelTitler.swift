import BoopstashCore
import FoundationModels

/// Titles from Apple's on-device model, falling back to `RuleTitler` when the
/// model is unavailable (Intel, Apple Intelligence off, model downloading) or
/// declines (guardrails, context size).
///
/// On-device only: this names `SystemLanguageModel.default` explicitly and
/// must never use `PrivateCloudComputeLanguageModel`, which sends the prompt
/// to Apple's servers (ADR 0001).
struct LiveModelTitler: Titler {
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    func title(for body: String, kind: ContentKind) async -> String {
        await modelTitle(for: body, kind: kind) ?? RuleTitler.title(for: body, kind: kind)
    }

    /// The model's own title, or nil when it is unavailable, throws or says
    /// nothing usable. Callers that remember what the model titled must use
    /// this, so a failure is never recorded as a model title (#15).
    func modelTitle(for body: String, kind: ContentKind) async -> String? {
        guard Self.isAvailable else { return nil }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: ModelTitle.instructions)
        do {
            let response = try await session.respond(to: ModelTitle.prompt(for: body, kind: kind))
            return ModelTitle.clean(response.content)
        } catch {
            return nil
        }
    }
}
