import Foundation
import UniformTypeIdentifiers

/// What an image capture may become: an attachment, stored as given
/// (#51). Paste, drops, the clipboard capture and Services all decide here.
public enum ImageImport {
    /// Screenshots and photos fit; a stash is not a photo library.
    public static let sizeLimit = 20 * 1024 * 1024

    /// The types kept, best first. Pasteboards often offer an image as
    /// both its original type and a TIFF that AppKit adds; the original is
    /// smaller and is what was copied.
    public static let supported: [UTType] = [.png, .jpeg, .heic, .gif, .webP, .tiff]

    public enum Refusal: Error, Equatable {
        case unsupported(type: String)
        case tooLarge(bytes: Int)
        case empty
    }

    public static func accepts(_ type: UTType) -> Bool {
        supported.contains { type.conforms(to: $0) }
    }

    /// The supported image type to read from a pasteboard or item that
    /// offers these type identifiers, or nil when none is an image.
    public static func preferredType(among identifiers: [String]) -> UTType? {
        let offered = identifiers.compactMap(UTType.init)
        return supported.first { candidate in offered.contains { $0.conforms(to: candidate) } }
    }

    /// Whether `data` of `type` may be stored. Returns the type to record.
    public static func check(_ data: Data, type: UTType) -> Result<UTType, Refusal> {
        guard accepts(type) else { return .failure(.unsupported(type: type.localizedDescription ?? type.identifier)) }
        guard !data.isEmpty else { return .failure(.empty) }
        guard data.count <= sizeLimit else { return .failure(.tooLarge(bytes: data.count)) }
        return .success(type)
    }

    /// The banner text for a refusal; `name` is the file's, when there is one.
    public static func message(for refusal: Refusal, name: String? = nil) -> String {
        let subject = name ?? "The image"
        switch refusal {
        case .unsupported(let type): return "\(subject) is \(type), which BoopStash does not keep."
        case .tooLarge(let bytes):
            return "\(subject) is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); the limit for images is 20 MB."
        case .empty: return "\(subject) is empty."
        }
    }
}
