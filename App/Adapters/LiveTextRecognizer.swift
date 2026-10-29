import Foundation
import Vision

/// Text in an image, read by Vision on this device (#53). Vision's text
/// recognition runs on device: nothing is sent anywhere (ADR 0001).
enum LiveTextRecognizer {
    /// The image's text, one observation per line, or nil when the image
    /// cannot be read. An image with no text gives "".
    static func text(in data: Data) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: data) else { return nil }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
