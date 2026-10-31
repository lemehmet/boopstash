import Foundation

/// The `boopstash` command (#156, ADR 0009): everything but reading stdin,
/// writing the output and opening the store, so it can be tested.
public enum CommandLineTool {
    public enum Command: Equatable, Sendable {
        /// Keep standard input as a new note, with these labels (#184),
        /// made if missing.
        case capture(title: String?, labels: [String] = [])
        /// `labels`: a note must carry every one, named in any case.
        case list(days: Int?, limit: Int, labels: [String] = [], json: Bool)
        case search(String, days: Int?, limit: Int, labels: [String] = [], json: Bool)
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
          some-command | boopstash [--title TITLE] [--label NAME]...
                                                      keep standard input as a note
          boopstash list [--days N] [--limit N] [--label NAME]... [--json]
          boopstash search TEXT... [--days N] [--limit N] [--label NAME]... [--json]
          boopstash show ID [--json]                  print a note (an ID prefix will do)
          boopstash --help | --version

        --label NAME, -l NAME   repeatable. With list and search, only notes
                                carrying every named label, in any case; with
                                a capture, label the note, making the label if
                                there is none.

        Notes are BoopStash's, on this Mac. The command reads only standard
        input: use `boopstash < file` for a file.
        """

    /// `arguments` without the program name. `standardInputIsTerminal`:
    /// with no command, piped input is a capture and a terminal gets help.
    public static func parse(_ arguments: [String], standardInputIsTerminal: Bool) throws(UsageError) -> Command {
        var rest = arguments[...]
        var json = false, days: Int?, limit = 20, title: String?, labels: [String] = []
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
            case "--label", "-l":
                let name = try value(after: argument).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw UsageError(message: "\(argument) needs a label name") }
                labels.append(name)
            case "--help", "-h": return .help
            case "--version", "-v": return .version
            default: throw UsageError(message: "unknown option \(argument)")
            }
        }
        guard let verb = words.first else {
            return standardInputIsTerminal && title == nil && labels.isEmpty ? .help : .capture(title: title, labels: labels)
        }
        let operands = Array(words.dropFirst())
        switch verb {
        case "capture", "add":
            guard operands.isEmpty else { throw UsageError(message: "capture reads standard input; it takes no text") }
            return .capture(title: title, labels: labels)
        case "list", "ls":
            guard operands.isEmpty else { throw UsageError(message: "list takes no text; did you mean search?") }
            return .list(days: days, limit: limit, labels: labels, json: json)
        case "search", "find":
            guard !operands.isEmpty else { throw UsageError(message: "search needs text to look for") }
            return .search(operands.joined(separator: " "), days: days, limit: limit, labels: labels, json: json)
        case "show", "cat":
            guard operands.count == 1 else { throw UsageError(message: "show needs one note ID") }
            guard labels.isEmpty else { throw UsageError(message: "show takes no --label; did you mean list?") }
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
            case .capture(let title, let labels):
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
                // Note and labels in one transaction: never one without the other.
                try store.save(note, labelNames: labels, now: now)
                output.wrote = true
                output.standardOutput = shortID(note.id) + "\n"
            case .list(let days, let limit, let names, let json):
                let labels = try labelIDs(names, in: store)
                let notes = try store.notes(matching: NoteQuery(days: days, labels: labels, limit: limit), now: now)
                let catalog = try store.labelCatalog()
                output.standardOutput = json ? try encode(notes, catalog: catalog, bodies: false) : table(notes, catalog: catalog)
            case .search(let text, let days, let limit, let names, let json):
                let labels = try labelIDs(names, in: store)
                let notes = try store.notes(matching: NoteQuery(text: text, days: days, labels: labels, limit: limit), now: now)
                let catalog = try store.labelCatalog()
                output.standardOutput = json ? try encode(notes, catalog: catalog, bodies: false) : table(notes, catalog: catalog)
                if notes.isEmpty, !json { output.status = 1 }
            case .show(let id, let json):
                let matches = try store.notes(withIDPrefix: id)
                guard matches.count == 1, let note = matches.first else {
                    return failure(matches.isEmpty ? "no note with ID \(id)" : "\(id) matches \(matches.count) notes; give more of the ID")
                }
                if json {
                    output.standardOutput = try encode([note], catalog: try store.labelCatalog(), bodies: true, single: true)
                } else {
                    output.standardOutput = note.body.hasSuffix("\n") || note.body.isEmpty ? note.body : note.body + "\n"
                }
            }
        } catch {
            return failure(error.localizedDescription)
        }
        return output
    }

    struct UnknownLabel: LocalizedError {
        let name: String
        var errorDescription: String? { "no label named \(name)" }
    }

    /// The IDs of the labels named, in any case; a name no label has is an
    /// error.
    static func labelIDs(_ names: [String], in store: NoteStore) throws -> Set<UUID> {
        try Set(names.map { name in
            guard let label = try store.label(named: name) else { throw UnknownLabel(name: name) }
            return label.id
        })
    }

    static func failure(_ message: String) -> Output {
        Output(standardError: "boopstash: \(message)\n", status: 1)
    }

    /// The first eight hex digits, as `list` shows them and `show` takes.
    public static func shortID(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    /// One line per note: short ID, last edit, title, then its labels'
    /// names in brackets.
    static func table(_ notes: [Note], catalog: LabelCatalog = LabelCatalog()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        formatter.timeZone = .current
        return notes.map { note in
            let title = note.title.isEmpty ? "Untitled" : note.title
            let names = catalog.labels(of: note.id).map(\.name)
            let labels = names.isEmpty ? "" : "  [\(names.joined(separator: ", "))]"
            return "\(shortID(note.id))  \(formatter.string(from: note.updatedAt).prefix(16))  \(title.replacingOccurrences(of: "\n", with: " "))\(labels)\n"
        }.joined()
    }

    struct Entry: Encodable {
        let id: String
        let title: String
        let created: Date
        let updated: Date
        let source: String?
        /// Always present; empty for a note without labels.
        let labels: [LabelEntry]
        let body: String?
    }

    struct LabelEntry: Encodable {
        let name: String
        let color: String
    }

    static func encode(_ notes: [Note], catalog: LabelCatalog, bodies: Bool, single: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let entries = notes.map {
            Entry(id: $0.id.uuidString.lowercased(), title: $0.title, created: $0.createdAt, updated: $0.updatedAt,
                  source: $0.sourceAppName, labels: catalog.labels(of: $0.id).map { LabelEntry(name: $0.name, color: $0.color) },
                  body: bodies ? $0.body : nil)
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
