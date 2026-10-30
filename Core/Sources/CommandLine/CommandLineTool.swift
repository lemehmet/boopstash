import Foundation

/// The `boopstash` command (#156, ADR 0009): everything but reading stdin,
/// writing the output and opening the store, so it can be tested.
public enum CommandLineTool {
    public enum Command: Equatable, Sendable {
        /// Keep standard input as a new note.
        case capture(title: String?)
        case list(days: Int?, limit: Int, json: Bool)
        case search(String, days: Int?, limit: Int, json: Bool)
        case show(String, json: Bool)
        case help
        case version
    }

    public struct UsageError: Error, Equatable, Sendable {
        public let message: String
    }

    public struct Output: Equatable, Sendable {
        public var standardOutput = ""
        public var standardError = ""
        public var status: Int32 = 0
        /// The store changed: tell the app.
        public var wrote = false
    }

    /// What a captured note records as its source, so the app can tell.
    public static let sourceAppName = "Terminal"

    /// The most a capture keeps: the text import limit (5 MB).
    public static let inputLimit = TextFileImport.sizeLimit

    public static let usage = """
        Usage:
          some-command | boopstash [--title TITLE]   keep standard input as a note
          boopstash list [--days N] [--limit N] [--json]
          boopstash search TEXT... [--days N] [--limit N] [--json]
          boopstash show ID [--json]                  print a note (an ID prefix will do)
          boopstash --help | --version

        Notes are BoopStash's, on this Mac. The command reads only standard
        input: use `boopstash < file` for a file.
        """

    /// `arguments` without the program name. `standardInputIsTerminal`:
    /// with no command, piped input is a capture and a terminal gets help.
    public static func parse(_ arguments: [String], standardInputIsTerminal: Bool) throws(UsageError) -> Command {
        var rest = arguments[...]
        var json = false, days: Int?, limit = 20, title: String?
        var words: [String] = []
        func value(after flag: String) throws(UsageError) -> String {
            guard let next = rest.popFirst() else { throw UsageError(message: "\(flag) needs a value") }
            return next
        }
        func number(after flag: String) throws(UsageError) -> Int {
            let text = try value(after: flag)
            guard let number = Int(text), number > 0 else { throw UsageError(message: "\(flag) needs a positive number, not \(text)") }
            return number
        }
        var literal = false
        while let argument = rest.popFirst() {
            if literal || !argument.hasPrefix("-") || argument == "-" {
                words.append(argument)
                continue
            }
            switch argument {
            case "--": literal = true
            case "--json": json = true
            case "--days", "-d": days = try number(after: argument)
            case "--limit", "-n": limit = try number(after: argument)
            case "--title", "-t": title = try value(after: argument)
            case "--help", "-h": return .help
            case "--version", "-v": return .version
            default: throw UsageError(message: "unknown option \(argument)")
            }
        }
        guard let verb = words.first else {
            return standardInputIsTerminal && title == nil ? .help : .capture(title: title)
        }
        let operands = Array(words.dropFirst())
        switch verb {
        case "capture", "add":
            guard operands.isEmpty else { throw UsageError(message: "capture reads standard input; it takes no text") }
            return .capture(title: title)
        case "list", "ls":
            guard operands.isEmpty else { throw UsageError(message: "list takes no text; did you mean search?") }
            return .list(days: days, limit: limit, json: json)
        case "search", "find":
            guard !operands.isEmpty else { throw UsageError(message: "search needs text to look for") }
            return .search(operands.joined(separator: " "), days: days, limit: limit, json: json)
        case "show", "cat":
            guard operands.count == 1 else { throw UsageError(message: "show needs one note ID") }
            return .show(operands[0], json: json)
        case "help": return .help
        default: throw UsageError(message: "unknown command \(verb)")
        }
    }

    /// Runs `command` on `store`. `input` is standard input, read only for
    /// a capture.
    public static func run(_ command: Command, store: NoteStore, input: () throws -> Data, version: String,
                           now: Date = Date()) -> Output {
        var output = Output()
        do {
            switch command {
            case .help:
                output.standardOutput = usage + "\n"
            case .version:
                output.standardOutput = "boopstash \(version)\n"
            case .capture(let title):
                let data: Data
                do { data = try input() } catch {
                    // Never a truncated note: a failed read keeps nothing.
                    return failure("could not read standard input: \(error.localizedDescription)")
                }
                guard data.count <= inputLimit else {
                    return failure("standard input is over \(inputLimit / 1024 / 1024) MB; BoopStash keeps notes up to that size")
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    return failure("standard input is not UTF-8 text")
                }
                guard text.contains(where: { !$0.isWhitespace }) else {
                    return failure("nothing on standard input to keep")
                }
                var note = Note(body: text, createdAt: now, sourceAppName: sourceAppName)
                if let title, !title.isEmpty {
                    note.title = title
                    note.titleIsUserSet = true
                } else {
                    note.title = RuleTitler.title(for: text, kind: ContentKind.detect(text))
                }
                try store.save(note)
                output.wrote = true
                output.standardOutput = shortID(note.id) + "\n"
            case .list(let days, let limit, let json):
                let notes = try store.notes(matching: NoteQuery(days: days, limit: limit), now: now)
                output.standardOutput = json ? try encode(notes, bodies: false) : table(notes)
            case .search(let text, let days, let limit, let json):
                let notes = try store.notes(matching: NoteQuery(text: text, days: days, limit: limit), now: now)
                output.standardOutput = json ? try encode(notes, bodies: false) : table(notes)
                if notes.isEmpty, !json { output.status = 1 }
            case .show(let id, let json):
                let matches = try store.notes(withIDPrefix: id)
                guard matches.count == 1, let note = matches.first else {
                    return failure(matches.isEmpty ? "no note with ID \(id)" : "\(id) matches \(matches.count) notes; give more of the ID")
                }
                if json {
                    output.standardOutput = try encode([note], bodies: true, single: true)
                } else {
                    output.standardOutput = note.body.hasSuffix("\n") || note.body.isEmpty ? note.body : note.body + "\n"
                }
            }
        } catch {
            return failure(error.localizedDescription)
        }
        return output
    }

    static func failure(_ message: String) -> Output {
        Output(standardError: "boopstash: \(message)\n", status: 1)
    }

    /// The first eight hex digits, as `list` shows them and `show` takes.
    public static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    static func table(_ notes: [Note]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        formatter.timeZone = .current
        return notes.map { note in
            let title = note.title.isEmpty ? "Untitled" : note.title
            return "\(shortID(note.id))  \(formatter.string(from: note.updatedAt).prefix(16))  \(title.replacingOccurrences(of: "\n", with: " "))\n"
        }.joined()
    }

    struct Entry: Encodable {
        let id: String
        let title: String
        let created: Date
        let updated: Date
        let source: String?
        let body: String?
    }

    static func encode(_ notes: [Note], bodies: Bool, single: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let entries = notes.map {
            Entry(id: $0.id.uuidString.lowercased(), title: $0.title, created: $0.createdAt, updated: $0.updatedAt,
                  source: $0.sourceAppName, body: bodies ? $0.body : nil)
        }
        let data = single ? try encoder.encode(entries[0]) : try encoder.encode(entries)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

extension NoteStore {
    /// Notes whose ID starts with `prefix` (case and dashes ignored), for
    /// `boopstash show`.
    public func notes(withIDPrefix prefix: String) throws -> [Note] {
        let wanted = prefix.lowercased().filter { $0 != "-" }
        guard !wanted.isEmpty, wanted.allSatisfy(\.isHexDigit) else { return [] }
        return try writer.read { db in try Note.fetchAll(db) }
            .filter { $0.id.uuidString.lowercased().filter { $0 != "-" }.hasPrefix(wanted) }
    }
}
