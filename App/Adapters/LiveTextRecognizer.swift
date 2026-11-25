import BoopstashCore
import Foundation
import ImageIO
import Vision

/// Text in an image, read by Vision on this device (#53). Vision's text
/// recognition runs on device: nothing is sent anywhere (ADR 0001).
enum LiveTextRecognizer {
    /// The image's text laid out as it reads in the picture (Core's
    /// `TextRows`, #243): what is on one visual row is one line, cells a
    /// tab apart. Nil when the image cannot be read; an image with no text
    /// gives "".
    static func text(in data: Data) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: data) else { return nil }
        // Vision's boxes are fractions of the width and of the height, from
        // the bottom left. Rows need one unit for both axes and y downwards,
        // so they are scaled to the picture; without its size, a square.
        let size = pixelSize(of: data) ?? CGSize(width: 1, height: 1)
        return TextRows.text(from: observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox.cgRect
            return TextObservation(text: text, box: CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                                           width: box.width * size.width, height: box.height * size.height))
        })
    }

    /// The picture's size as it is shown: a photo stored on its side has
    /// its width and height swapped, as Vision reads it upright.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}
