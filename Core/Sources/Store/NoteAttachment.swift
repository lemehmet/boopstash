import Foundation
import GRDB
import UniformTypeIdentifiers

/// An image (or other file) a note shows. Its bytes live in a file beside
/// the database, never in the note: the body refers to it as
/// `![](attachment:<uuid>)`, so the body stays portable markdown (ADR 0002).
public struct NoteAttachment: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The note it was added to. Other notes may refer to it too (a copied
    /// reference); clean-up goes by references, this only says who owns it.
    public var noteID: UUID?
    /// A uniform type identifier, such as `public.png`.
    public var contentType: String
    public var byteSize: Int
    public var createdAt: Date { didSet { createdAt = createdAt.storedPrecision } }
    /// Text found in the image on device (milestone 4), for search.
    public var recognizedText: String?

    public init(id: UUID = UUID(), noteID: UUID?, contentType: String, byteSize: Int, createdAt: Date = Date(), recognizedText: String? = nil) {
        self.id = id
        self.noteID = noteID
        self.contentType = contentType
        self.byteSize = byteSize
        self.createdAt = createdAt.storedPrecision
        self.recognizedText = recognizedText
    }

    /// The file name it is stored and exported under: the ID and the type's
    /// usual extension, so other apps open the exported file.
    public var fileName: String {
        let ext = UTType(contentType)?.preferredFilenameExtension ?? "bin"
        return "\(id.uuidString.lowercased()).\(ext)"
    }
}

extension NoteAttachment: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "attachment"
}

/// The `![alt](attachment:<uuid>)` references in a note body.
public enum AttachmentReference {
    public static let scheme = "attachment:"

    /// The markdown that shows an attachment. Backslashes and brackets in
    /// the alt text are escaped, so the reference always parses back.
    public static func markdown(for id: UUID, alt: String = "") -> String {
        let escaped = alt.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "![\(escaped)](\(scheme)\(id.uuidString.lowercased()))"
    }

    /// `![…](attachment:<uuid>)`; the alt text may hold escaped brackets.
    /// The scheme matches in any case, as the preview reads it, so a
    /// reference the preview shows is never one clean-up overlooks.
    static let pattern = try! NSRegularExpression(
        pattern: #"!\[(?:[^\]\\]|\\.)*\]\((?i:attachment):([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)"#
    )

    /// Every attachment a body refers to. A reference inside a code span
    /// still counts: keeping a file too long is harmless, deleting one a note
    /// shows is not.
    public static func ids(in body: String) -> Set<UUID> {
        let range = NSRange(body.startIndex..., in: body)
        return Set(pattern.matches(in: body, range: range).compactMap { match in
            Range(match.range(at: 1), in: body).flatMap { UUID(uuidString: String(body[$0])) }
        })
    }

    /// The body with each reference's destination replaced by `destination`
    /// (for export: a relative path). Unknown IDs are left as they are.
    public static func rewriting(_ body: String, _ destination: (UUID) -> String?) -> String {
        let ns = body as NSString
        var result = ""
        var last = 0
        for match in pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let idRange = match.range(at: 1)
            guard let id = UUID(uuidString: ns.substring(with: idRange)), let target = destination(id) else { continue }
            // Replace "attachment:<uuid>" (the scheme sits just before the ID).
            let start = idRange.location - scheme.utf16.count
            result += ns.substring(with: NSRange(location: last, length: start - last)) + target
            last = NSMaxRange(idRange)
        }
        return result + ns.substring(from: last)
    }
}
