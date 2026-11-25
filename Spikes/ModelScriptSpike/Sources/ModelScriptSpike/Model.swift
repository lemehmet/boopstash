import Foundation
import FoundationModels
import SpikeKit

/// The script as guided generation returns it: one string field, so the
/// reply cannot carry prose or fences.
@Generable
struct ScriptDraft {
    @Guide(description: "The complete JavaScript source of the script. It defines function main(state).")
    var script: String
}

/// One conversation with the on-device model. This names
/// `SystemLanguageModel.default` and must never use
/// `PrivateCloudComputeLanguageModel`, which sends the prompt to Apple's
/// servers (ADR 0001).
struct ModelChat {
    let session: LanguageModelSession
    let guided: Bool

    static var availability: String {
        switch SystemLanguageModel.default.availability {
        case .available: "available"
        case .unavailable(let reason): "unavailable (\(reason))"
        }
    }

    init(variation: Variation) {
        session = LanguageModelSession(model: SystemLanguageModel.default,
                                       instructions: Prompts.instructions(variation.wording, guided: variation.guided,
                                                                          wholeText: variation.fullSample))
        guided = variation.guided
    }

    /// The reply as text: the `script` field under guided generation, the
    /// whole reply otherwise. The cap keeps a reply that never ends from
    /// holding up the run.
    func ask(_ prompt: String) async throws -> String {
        let options = GenerationOptions(maximumResponseTokens: 1500)
        if guided {
            return try await session.respond(to: prompt, generating: ScriptDraft.self, options: options).content.script
        }
        return try await session.respond(to: prompt, options: options).content
    }

    /// The error's case name, such as `exceededContextWindowSize`, without
    /// its payload.
    static func name(of error: Error) -> String {
        let text = String(describing: error)
        return String(text.prefix { $0 != "(" && $0 != ":" })
    }
}
