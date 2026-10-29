import Foundation
import GRDB
import Markdown
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
    /// Every destination form CommonMark (and so the preview) reads: bare
    /// or in angle brackets, with or without a title (#88). Group 1 is the
    /// alt text, group 2 the ID.
    /// `.` crosses lines, so an escaped line break inside an alt text or
    /// title is still an escape (#104).
    static let pattern = try! NSRegularExpression(
        pattern: #"!\[((?:[^\]\\]|\\.)*)\]\(\s*<?(?i:attachment):([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})>?(?:\s+(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\((?:[^)\\]|\\.)*\)))?\s*\)"#,
        options: [.dotMatchesLineSeparators]
    )

    /// A link reference definition naming an attachment (`[img]: attachment:<uuid>`),
    /// which reference-style images (`![plot][img]`) use (#104). Group 1 is
    /// the ID.
    static let definitionPattern = try! NSRegularExpression(
        pattern: #"^ {0,3}\[(?:[^\]\\]|\\.)+\]:[ \t]*\n?[ \t]*<?(?i:attachment):([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})>?"#,
        options: [.anchorsMatchLines, .dotMatchesLineSeparators]
    )

    /// Where each attachment ID sits, inline images and definitions both,
    /// in order.
    static func idRanges(in body: String) -> [NSRange] {
        let whole = NSRange(location: 0, length: (body as NSString).length)
        let inline = pattern.matches(in: body, range: whole).map { $0.range(at: 2) }
        let defined = definitionPattern.matches(in: body, range: whole).map { $0.range(at: 1) }
        return (inline + defined).sorted { $0.location < $1.location }
    }

    /// Every attachment a body refers to. A reference inside a code span
    /// still counts: keeping a file too long is harmless, deleting one a note
    /// shows is not.
    public static func ids(in body: String) -> Set<UUID> {
        let ns = body as NSString
        let matched = Set(idRanges(in: body).compactMap { UUID(uuidString: ns.substring(with: $0)) })
        return matched.union(parsedIDs(in: body))
    }

    /// The attachments the Markdown parser resolves, as the preview does:
    /// whatever the form (a definition inside a quote, CRLF, anything
    /// CommonMark allows), an image the preview shows is one clean-up keeps
    /// (#113). Only bodies that mention the scheme are parsed.
    static func parsedIDs(in body: String) -> Set<UUID> {
        guard body.range(of: scheme, options: .caseInsensitive) != nil else { return [] }
        var collector = ImageSources()
        collector.visit(Document(parsing: body))
        return Set(collector.sources.compactMap(id(fromSource:)))
    }

    static func id(fromSource source: String) -> UUID? {
        guard source.lowercased().hasPrefix(scheme) else { return nil }
        return UUID(uuidString: String(source.dropFirst(scheme.count)))
    }

    /// Whether the body has anything to read besides its images, judged by
    /// the parser so reference-style images count as images, not text
    /// (#114).
    public static func hasText(besidesImages body: String) -> Bool {
        var collector = ImageSources()
        collector.visit(Document(parsing: body))
        return collector.hasText
    }

    /// Each reference with where it is (UTF-16, as the editor counts), its
    /// attachment and its alt text unescaped, in order.
    public static func matches(in body: String) -> [(range: NSRange, id: UUID, alt: String)] {
        let ns = body as NSString
        return pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let id = UUID(uuidString: ns.substring(with: match.range(at: 2))) else { return nil }
            // Escapes can cover a line break too (#115).
            let escaped = ns.substring(with: match.range(at: 1))
            let alt = Self.unescape.stringByReplacingMatches(in: escaped, range: NSRange(location: 0, length: (escaped as NSString).length), withTemplate: "$1")
            return (match.range, id, alt)
        }
    }

    static let unescape = try! NSRegularExpression(pattern: #"\\(.)"#, options: [.dotMatchesLineSeparators])

    /// The body without its image references: its text alone, for deciding
    /// whether there is anything to read beyond the images.
    public static func removingReferences(from body: String) -> String {
        let inline = pattern.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
        return definitionPattern.stringByReplacingMatches(in: inline, range: NSRange(location: 0, length: (inline as NSString).length), withTemplate: "")
    }

    /// The body with each reference's destination replaced by `destination`
    /// (for export: a relative path). Unknown IDs are left as they are.
    public static func rewriting(_ body: String, _ destination: (UUID) -> String?) -> String {
        let ns = body as NSString
        var result = ""
        var last = 0
        for idRange in idRanges(in: body) {
            guard let id = UUID(uuidString: ns.substring(with: idRange)), let target = destination(id) else { continue }
            // Replace "attachment:<uuid>" (the scheme sits just before the ID).
            let start = idRange.location - scheme.utf16.count
            result += ns.substring(with: NSRange(location: last, length: start - last)) + target
            last = NSMaxRange(idRange)
        }
        return result + ns.substring(from: last)
    }
}

/// Walks parsed markdown for image sources, and notes whether there is any
/// text outside images.
struct ImageSources: MarkupWalker {
    var sources: [String] = []
    var hasText = false

    mutating func visitImage(_ image: Markdown.Image) {
        if let source = image.source { sources.append(source) }
        // Alt text is the image's, not the note's.
    }

    mutating func visitText(_ text: Markdown.Text) {
        if !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true }
    }

    mutating func visitInlineCode(_ code: InlineCode) { if !code.code.isEmpty { hasText = true } }
    mutating func visitCodeBlock(_ code: CodeBlock) { if !code.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true } }
    mutating func visitHTMLBlock(_ html: HTMLBlock) { hasText = true }
    mutating func visitInlineHTML(_ html: InlineHTML) { hasText = true }
}
