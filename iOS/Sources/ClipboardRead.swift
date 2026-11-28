import BoopstashCore
import UIKit
import UniformTypeIdentifiers

/// Reads the general pasteboard, only ever inside a paste or From
/// Clipboard the user asked for (ADR 0001). What to take is Core's
/// decision (`ClipboardPaste`); this only fetches it.
enum ClipboardRead {
    enum Outcome {
        case text(String)
        /// No text worth keeping, but an image (#310): its bytes and type.
        case image(Data, UTType)
        case refused(CapturePolicy.Decision)
        /// An image that is not kept and could not be converted, by name.
        case unsupportedImage(String)
        /// An image is there and its bytes did not come.
        case unreadableImage
        /// Nothing to keep; `blank` is text that is only whitespace, which
        /// a paste into a note still inserts.
        case empty(blank: String?)
    }

    @MainActor
    static func read(from pasteboard: UIPasteboard = .general) -> Outcome {
        let types = pasteboard.types
        // The refusal first: a refused clipboard's contents are not read.
        if case .refuse(let decision) = ClipboardPaste.decide(types: types, hasText: false) { return .refused(decision) }
        let string = pasteboard.hasStrings ? pasteboard.string : nil
        let hasText = string.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        switch ClipboardPaste.decide(types: types, hasText: hasText) {
        case .refuse(let decision):
            return .refused(decision)
        case .text:
            return .text(string ?? "")
        case .image(let type):
            guard let data = pasteboard.data(forPasteboardType: type.identifier) else { return .unreadableImage }
            return .image(data, type)
        case .otherImage(let name):
            // The system can often draw what is not kept as it is: as PNG.
            guard let data = pasteboard.image?.pngData() else { return .unsupportedImage(name) }
            return .image(data, .png)
        case .nothing:
            return .empty(blank: string.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}
