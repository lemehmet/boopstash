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
        let fallback = RuleTitler.title(for: body, kind: kind)
        guard Self.isAvailable else { return fallback }
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: ModelTitle.instructions)
        do {
            let response = try await session.respond(to: ModelTitle.prompt(for: body, kind: kind))
            return ModelTitle.clean(response.content) ?? fallback
        } catch {
            return fallback
        }
    }
}
