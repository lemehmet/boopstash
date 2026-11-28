import Foundation
import UniformTypeIdentifiers

/// What a paste takes from a clipboard that may hold text, an image or
/// both (#310): the decision the iOS editor's Paste and From Clipboard
/// share, from the clipboard's type identifiers alone and whether it has
/// text worth keeping. Nothing here reads a pasteboard.
public enum ClipboardPaste {
    public enum Decision: Equatable, Sendable {
        /// A password manager's item or one marked not to be kept (ADR 0001).
        case refuse(CapturePolicy.Decision)
        case text
        /// No text, but an image of a type that is kept: read it as this.
        case image(UTType)
        /// No text, and an image only in types that are not kept as they
        /// are (the name is the first such type's). The caller may still
        /// have the system convert it; otherwise it is refused by name.
        case otherImage(String)
        case nothing
    }

    /// Refusals come first, whatever else is there. Text wins over an
    /// image when there is any, as ⌘V does on the Mac (ADR 0003): the body
    /// is text, and what was copied with a picture beside it is the text.
    public static func decide(types: [String], hasText: Bool) -> Decision {
        let policy = CapturePolicy.decide(types: types)
        guard policy == .accept else { return .refuse(policy) }
        if hasText { return .text }
        if let type = ImageImport.preferredType(among: types) { return .image(type) }
        if let other = types.compactMap(UTType.init).first(where: { $0.conforms(to: .image) }) {
            return .otherImage(other.localizedDescription ?? other.identifier)
        }
        return .nothing
    }

    /// Why a refused paste was refused; `verb` is "pasted" or "saved".
    public static func message(for refusal: CapturePolicy.Decision, verb: String) -> String? {
        switch refusal {
        case .refuseConcealed: "Not \(verb): the clipboard holds a password manager item."
        case .refuseTransient: "Not \(verb): the app it came from marked it as not to be kept."
        case .accept: nil
        }
    }
}

/// Insert Text Below (#243, #310): where an image's text goes in a note,
/// as an edit of the note's text.
public enum ImageTextInsertion {
    public struct Edit: Equatable, Sendable {
        /// Where the text is inserted, in UTF-16 units.
        public var location: Int
        /// What is inserted: a line break, then the image's text.
        public var text: String
        /// The inserted image text, to select afterwards.
        public var selection: NSRange
    }

    public enum Outcome: Equatable, Sendable {
        case edit(Edit)
        /// The note no longer refers to the image.
        case gone
        /// The image is in the note more than once and none is where the
        /// chosen one was: the text never goes under another copy.
        case ambiguous

        /// What to tell the user when nothing is inserted; nil for an edit.
        public var message: String? {
            switch self {
            case .edit: nil
            case .gone: "The image is no longer in this note, so its text was not inserted."
            case .ambiguous: "The note changed, and the image you chose cannot be told from its other copies, so its text was not inserted."
            }
        }
    }

    /// The image reference a selection is on: the one the caret is in or
    /// at an end of, or that a selection overlaps. With several, the first.
    public static func reference(in text: String, at selection: NSRange) -> (range: NSRange, id: UUID)? {
        let found = AttachmentReference.matches(in: text).first { match in
            selection.length == 0
                ? selection.location >= match.range.location && selection.location <= NSMaxRange(match.range)
                : NSIntersectionRange(selection, match.range).length > 0
        }
        return found.map { ($0.range, $0.id) }
    }

    /// The edit that puts `imageText` on a line of its own under the line
    /// of the reference to `id`. Reading an image takes a moment and the
    /// note may change meanwhile, so the reference is found again in the
    /// text as it now is: the one still starting at `chosenAt`, or else
    /// the only one there is.
    public static func insertion(of imageText: String, under id: UUID, chosenAt: Int?, in text: String) -> Outcome {
        let references = AttachmentReference.matches(in: text).filter { $0.id == id }
        guard !references.isEmpty else { return .gone }
        guard let reference = references.first(where: { $0.range.location == chosenAt }) ?? (references.count == 1 ? references[0] : nil) else {
            return .ambiguous
        }
        var lineEnd = 0
        (text as NSString).getLineStart(nil, end: nil, contentsEnd: &lineEnd, for: NSRange(location: NSMaxRange(reference.range), length: 0))
        return .edit(Edit(location: lineEnd, text: "\n" + imageText,
                          selection: NSRange(location: lineEnd + 1, length: (imageText as NSString).length)))
    }
}
