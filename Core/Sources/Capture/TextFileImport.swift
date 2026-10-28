import Foundation
import UniformTypeIdentifiers

/// What a dropped file may become: a note holding its text. Images arrive
/// with attachments in milestone 4; anything else is declined with a reason.
public enum TextFileImport {
    /// A stash of buffers, not a file manager: bigger files are refused
    /// rather than slowing every search and edit.
    public static let sizeLimit = 5 * 1024 * 1024

    public enum Refusal: Error, Equatable {
        case notText
        case tooLarge(bytes: Int)
        case unreadable
    }

    /// Whether a file of this type is worth reading. Only known binary
    /// families are turned away by type: plenty of text has no registered
    /// type (`nginx.conf`, `.env`, `Dockerfile`), so the content decides
    /// for everything else.
    public static func accepts(_ type: UTType) -> Bool {
        let binary: [UTType] = [.image, .audiovisualContent, .archive, .pdf, .executable, .bundle, .font, .spreadsheet, .presentation]
        return !binary.contains { type.conforms(to: $0) }
    }

    /// The text of a dropped file, if it is text. UTF-8 first (with or without a BOM),
    /// then UTF-16 when a BOM says so, then Foundation's guess. A NUL byte
    /// in a file that is not UTF-16 means binary, which is refused rather
    /// than stored as noise.
    public static func text(from data: Data, type: UTType?) -> Result<String, Refusal> {
        if let type, !accepts(type) { return .failure(.notText) }
        guard data.count <= sizeLimit else { return .failure(.tooLarge(bytes: data.count)) }
        // UTF-32's BOMs start with UTF-16's (FF FE 00 00), so check them first.
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: data, encoding: .utf32).map(Result.success) ?? .failure(.unreadable)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16).map(Result.success) ?? .failure(.unreadable)
        }
        if data.contains(0) { return .failure(.notText) }
        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = body.dropFirst(3) }
        if let text = String(data: body, encoding: .utf8) { return .success(text) }
        var converted: NSString?
        let encoding = NSString.stringEncoding(for: body, encodingOptions: [.allowLossyKey: false], convertedString: &converted, usedLossyConversion: nil)
        guard encoding != 0, let converted else { return .failure(.unreadable) }
        return .success(converted as String)
    }

    /// The note title for a file: its name without the extension, unless
    /// that leaves nothing.
    public static func title(forFileNamed name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// Reads until `limit` bytes or the end. One read can return less than
    /// asked before the end (a pipe hands over what it has), so a single
    /// call could save the start of a file as all of it. `read` is asked
    /// for at most the bytes still wanted.
    public static func readPrefix(limit: Int, read: (Int) throws -> Data?) rethrows -> Data {
        var data = Data()
        while data.count < limit, let chunk = try read(limit - data.count), !chunk.isEmpty {
            data.append(chunk)
        }
        return data
    }
}
