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
    /// the export.
    public static func files(for notes: [Note], timeZone: TimeZone = .current) -> [File] {
        var used: Set<String> = []
        return notes.sorted { $0.createdAt < $1.createdAt }.map { note in
            let base = "\(day(note.createdAt, timeZone: timeZone)) \(safeName(note.title.isEmpty ? "Untitled" : note.title))"
            var name = base + ".md"
            var counter = 2
            while used.contains(name.lowercased()) {
                name = "\(base) \(counter).md"
                counter += 1
            }
            used.insert(name.lowercased())
            return File(name: name, contents: document(for: note))
        }
    }

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
        return String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func day(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(dateSeparator: .dash, timeZone: timeZone).year().month().day())
    }
}
