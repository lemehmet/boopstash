import BoopstashCore
import CoreML
import Foundation

/// Sentence embeddings from the bundled all-MiniLM-L6-v2 (#157), on device:
/// the text is tokenised by Core's `WordPieceTokenizer` and the Core ML
/// model returns a unit vector. Nothing leaves the device.
final class LiveEmbedder: @unchecked Sendable {
    static let shared = LiveEmbedder()

    // MLModel predictions are safe from several threads; both are set once.
    private let model: MLModel?
    private let tokenizer: WordPieceTokenizer?

    private init() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = Bundle.main.url(forResource: "MiniLM", withExtension: "mlmodelc").flatMap { try? MLModel(contentsOf: $0, configuration: configuration) }
        tokenizer = Bundle.main.url(forResource: "vocab", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { WordPieceTokenizer(vocabulary: $0) }
    }

    var isAvailable: Bool { model != nil && tokenizer != nil }

    func embed(_ text: String) -> [Float]? {
        guard let model, let tokenizer, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let encoding = tokenizer.encode(text)
        guard let ids = try? MLMultiArray(shape: [1, NSNumber(value: tokenizer.length)], dataType: .int32),
              let mask = try? MLMultiArray(shape: [1, NSNumber(value: tokenizer.length)], dataType: .int32)
        else { return nil }
        for index in 0..<tokenizer.length {
            ids[index] = NSNumber(value: encoding.ids[index])
            mask[index] = NSNumber(value: encoding.mask[index])
        }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask]),
              let output = try? model.prediction(from: input).featureValue(for: "embedding")?.multiArrayValue
        else { return nil }
        return (0..<output.count).map { output[$0].floatValue }
    }
}
