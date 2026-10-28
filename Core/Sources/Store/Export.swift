import Foundation

/// Turns notes into a folder of markdown files (ADR 0002: export is the
/// answer to the store being opaque). Pure: the app writes what this returns.
public enum NoteExport {
    public struct File: Equatable, Sendable {
        public var name: String
        public var contents: String
    }

    /// One file per note, named `<date> <title>.md` so a folder listing sorts
    /// by creation and reads like the app's list. Names are unique within
    /// the export under Unicode case folding and canonical equivalence, which
    /// is how APFS compares them ("οσ" and "ος", or "é" and "e\u{301}", are
    /// one name there).
    public static func files(for notes: [Note], timeZone: TimeZone = .current) -> [File] {
        var used: Set<String> = []
        // APFS also ignores normalization ("é" and "e\u{301}" are one file
        // there). Swift String equality is canonical equivalence already,
        // so the set below treats them as one name without more work (#17).
        func key(_ name: String) -> String { name.folding(options: [.caseInsensitive], locale: nil) }
        return notes.sorted { $0.createdAt < $1.createdAt }.map { note in
            let base = "\(day(note.createdAt, timeZone: timeZone)) \(safeName(note.title.isEmpty ? "Untitled" : note.title))"
            var name = base + ".md"
            var counter = 2
            while used.contains(key(name)) {
                name = "\(base) \(counter).md"
                counter += 1
            }
            used.insert(key(name))
            return File(name: name, contents: document(for: note))
        }
    }

    /// File name components are limited to 255 bytes of UTF-8 on APFS and
    /// most Linux file systems. The title gets what is left after the date,
    /// a collision counter and the extension, with room to spare.
    static let titleByteLimit = 200

    /// YAML front matter for what the body does not carry, then the body as
    /// it is. Values are quoted so a title with a colon stays one value.
    public static func document(for note: Note) -> String {
        var lines = ["---"]
        lines.append("title: \(quoted(note.title))")
        lines.append("created: \(timestamp(note.createdAt))")
        lines.append("updated: \(timestamp(note.updatedAt))")
        if let app = note.sourceAppName { lines.append("source: \(quoted(app))") }
        lines.append("id: \(note.id.uuidString)")
        lines.append("---")
        lines.append("")
        var document = lines.joined(separator: "\n") + "\n" + note.body
        if !document.hasSuffix("\n") { document += "\n" }
        return document
    }

    /// Characters that are illegal or awkward in file names on macOS, Windows
    /// and Linux are replaced, runs of whitespace collapse, and the result is
    /// kept short enough for every file system.
    static func safeName(_ title: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var name = title.unicodeScalars.map { illegal.contains($0) ? "-" : String($0) }.joined()
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-")))
        if name.isEmpty { name = "Untitled" }
        // Whole characters only, so an emoji or accent is never split.
        var capped = ""
        for character in name.prefix(80) {
            guard capped.utf8.count + String(character).utf8.count <= titleByteLimit else { break }
            capped.append(character)
        }
        return capped.trimmingCharacters(in: .whitespaces)
    }

    /// A YAML double-quoted scalar: backslash and quote escaped, and every
    /// character outside YAML's printable set escaped (#18), along with the
    /// line breaks that would otherwise be folded. A title with a newline, a
    /// NUL or a noncharacter reads back exactly.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\0": out += "\\0"
            case "\u{85}": out += "\\N"
            case "\u{2028}": out += "\\L"
            case "\u{2029}": out += "\\P"
            default:
                if isYAMLPrintable(scalar) {
                    out.unicodeScalars.append(scalar)
                } else if scalar.value <= 0xFF {
                    out += String(format: "\\x%02X", scalar.value)
                } else if scalar.value <= 0xFFFF {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out += String(format: "\\U%08X", scalar.value)
                }
            }
        }
        return out + "\""
    }

    /// YAML 1.2's printable set: TAB, LF, CR, x20–x7E, NEL, xA0–xD7FF,
    /// xE000–xFFFD and x10000–x10FFFF. The BOM (xFEFF) is printable but
    /// confuses readers mid-stream, so it is escaped too.
    static func isYAMLPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D, 0x20...0x7E, 0x85: true
        case 0xFEFF: false
        case 0xA0...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
        default: false
        }
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func day(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash, timeZone: timeZone).year().month().day())
    }
}
