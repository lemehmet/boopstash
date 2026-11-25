import Foundation

/// Where a script in the workbench (#247) starts when it is not a script
/// from the library: the shapes ADR 0013 names in place of a model's
/// draft. Each is a script body without a header; Save as Script adds one.
public enum ScriptSkeleton: String, CaseIterable, Sendable, Identifiable {
    case blank
    case lineByLine
    case wrappedRows

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .blank: "Blank Script"
        case .lineByLine: "Line by Line"
        case .wrappedRows: "Rows with Wrapped Descriptions"
        }
    }

    public var summary: String {
        switch self {
        case .blank: "A main function and nothing else."
        case .lineByLine: "Changes, keeps or drops each line on its own."
        case .wrappedRows: "Rows of a pasted table whose descriptions wrap over several lines."
        }
    }

    /// The JavaScript. As it stands each one runs and leaves the text as
    /// it is, or, for the rows, rewrites each row on one line.
    public var source: String {
        switch self {
        case .blank:
            """
            function main(state) {
              // state.text is the selection, or the whole note when nothing is selected.
              // Assign the result to it. state.postError("why") stops without changing anything.
              state.text = state.text;
            }

            """
        case .lineByLine:
            """
            function main(state) {
              const out = [];
              for (const line of state.text.split("\\n")) {
                // Change one line here. Push nothing to drop the line.
                out.push(line);
              }
              // Join the lines: an array assigned to state.text arrives as one comma-separated line.
              state.text = out.join("\\n");
            }

            """
        case .wrappedRows:
            """
            function main(state) {
              // A row starts on a line that matches rowStart: here a name, a number, and the
              // start of a description. A line that does not match continues the description
              // of the row before it. The first headerLines lines are left out.
              const rowStart = /^(\\S+)\\s+(\\d+)\\b\\s*(.*)$/;
              const headerLines = 1;

              const rows = [];
              for (const line of state.text.split("\\n").slice(headerLines)) {
                const start = line.match(rowStart);
                if (start) rows.push({ name: start[1], value: start[2], words: start[3] ? [start[3].trim()] : [] });
                else if (rows.length && line.trim()) rows[rows.length - 1].words.push(line.trim());
              }
              if (!rows.length) {
                state.postError("No line looks like the start of a row. Change rowStart.");
                return;
              }
              // Write one line per row here.
              state.text = rows.map(row => row.name + " " + row.value + " " + row.words.join(" ")).join("\\n");
            }

            """
        }
    }
}

/// The Boop header (ADR 0005) of a script saved from the workbench.
public enum ScriptHeader {
    /// A script's name as it is saved: one line, no surrounding space.
    public static func cleanName(_ name: String) -> String {
        name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The `/** … **/` header: `api`, `name`, and the other fields that
    /// have a value. Every `/` in a value is written `\/`, which JSON
    /// reads as `/`, so no value can end the comment early.
    public static func make(name: String, description: String = "", author: String? = nil, icon: String? = nil,
                            tags: [String] = []) -> String {
        var fields = ["\"api\": 1", "\"name\": \(quoted(cleanName(name)))"]
        func add(_ key: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            fields.append("\"\(key)\": \(quoted(value))")
        }
        add("description", description)
        add("author", author)
        add("icon", icon)
        add("tags", tags.joined(separator: ","))
        return "/**\n{\n" + fields.map { "  " + $0 }.joined(separator: ",\n") + "\n}\n**/\n"
    }

    /// A JSON string, with `/` escaped.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "/": out += "\\/"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// `source` without its Boop header, when it starts with one: what the
    /// workbench's editor shows of a library script. A script whose first
    /// comment is not a Boop header is returned whole.
    public static func body(of source: String) -> String {
        guard let header = leadingHeader(of: source) else { return source }
        return String(source[header.upperBound...].drop(while: \.isNewline))
    }

    /// The range of a Boop header that `source` opens with (only white
    /// space before it), found the way `BoopScript.parse` finds it.
    static func leadingHeader(of source: String) -> Range<String.Index>? {
        guard let open = source.range(of: "/**"),
              source[..<open.lowerBound].allSatisfy(\.isWhitespace),
              let close = source.range(of: "**/", range: open.upperBound..<source.endIndex),
              (try? BoopScript.parse(String(source[..<close.upperBound]), id: "", bundled: false).get()) != nil
        else { return nil }
        return open.lowerBound..<close.upperBound
    }

    /// The file to save: the header for `name`, then the script without
    /// any header it came with.
    public static func file(name: String, description: String = "", author: String? = nil, icon: String? = nil,
                            tags: [String] = [], script: String) -> String {
        var body = body(of: script)
        if !body.hasSuffix("\n") { body += "\n" }
        return make(name: name, description: description, author: author, icon: icon, tags: tags) + "\n" + body
    }
}

/// Saving a workbench script into the user's Scripts folder without
/// writing over anything silently.
public enum ScriptSave {
    /// A `.js` file already in the Scripts folder, and the name in its
    /// header when it has one that reads.
    public struct Existing: Sendable, Hashable {
        public var fileName: String
        public var scriptName: String?

        public init(fileName: String, scriptName: String?) {
            self.fileName = fileName
            self.scriptName = scriptName
        }
    }

    public enum Clash: Sendable, Hashable {
        /// One of the user's own scripts has the name, in this file; saving
        /// replaces that file.
        case yours(fileName: String)
        /// A bundled script or built-in command has the name; saving adds
        /// a file, and the user's script takes its place in the picker.
        case bundled
    }

    public enum Plan: Sendable, Hashable {
        /// Not saved, and why.
        case refused(String)
        /// Nothing has the name: a new file.
        case write(fileName: String)
        /// Something has the name. Nothing is written until the user
        /// confirms; then `fileName` is the file to write.
        case clash(Clash, fileName: String)

        /// What the workbench asks before a clashing save.
        public func question(name: String) -> String? {
            guard case .clash(let clash, _) = self else { return nil }
            switch clash {
            case .yours: return "You already have a script named \(name). Replace it?"
            case .bundled: return "A script that comes with BoopStash is named \(name). Yours will take its place in the picker. Save it?"
            }
        }
    }

    /// What saving a script as `name` would do. Names clash without regard
    /// to case, as file names do on a Mac and as the catalog shadows a
    /// bundled script (`ScriptCatalog.merge`); a new file's name never matches
    /// an existing file's, whatever that file holds.
    public static func plan(name: String, existing: [Existing], bundledNames: [String]) -> Plan {
        let name = ScriptHeader.cleanName(name)
        guard !name.isEmpty else { return .refused("Give the script a name.") }
        let key = ScriptCatalog.nameKey(name)
        if let mine = existing.first(where: { $0.scriptName.map(ScriptCatalog.nameKey) == key }) {
            return .clash(.yours(fileName: mine.fileName), fileName: mine.fileName)
        }
        let fileName = freeFileName(for: name, taken: existing.map(\.fileName))
        if bundledNames.contains(where: { ScriptCatalog.nameKey($0) == key }) {
            return .clash(.bundled, fileName: fileName)
        }
        return .write(fileName: fileName)
    }

    /// `Numbers to Links` → `NumbersToLinks.js`: the name's letters and
    /// digits, each word capitalised, as Boop names its files. A name with
    /// none is `Script.js`.
    public static func fileStem(for name: String) -> String {
        let words = name.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        let stem = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return stem.isEmpty ? "Script" : String(stem.prefix(60))
    }

    /// The stem's file, or the first of `Stem2.js`, `Stem3.js`, … that no
    /// file in the folder has.
    static func freeFileName(for name: String, taken: [String]) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        let stem = fileStem(for: name)
        var candidate = "\(stem).js"
        var number = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(stem)\(number).js"
            number += 1
        }
        return candidate
    }
}

/// One run in the workbench, turned into what the sheet shows: the diff of
/// the result against the selection or the whole note, the edits Keep
/// would apply, and what the script said.
public struct ScriptWorkbenchResult: Sendable {
    public struct Note: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable { case error, info }
        public var id: Int
        public var kind: Kind
        public var text: String
    }

    /// The replacements Keep applies, in the coordinates of the text the
    /// run was made on. Nil when the run produced nothing to apply.
    public var edits: [(NSRange, String)]?
    public var content: DiffReviewContent
    /// Errors (the script's own, an exception, the time limit) and then
    /// what it posted with `postInfo`.
    public var notes: [Note]
    /// One line: how the run ended.
    public var status: String

    /// There is a change to keep.
    public var canKeep: Bool { edits != nil && !content.isEmpty }

    public static func make(response: ScriptResponse, fullText: String, selections: [NSRange], context: Int = 3) -> ScriptWorkbenchResult {
        let texts = response.errors.map { (Note.Kind.error, $0) } + response.infos.map { (Note.Kind.info, $0) }
        let notes = texts.enumerated().map { Note(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
        let empty = DiffReviewContent(parts: [])
        guard response.errors.isEmpty else {
            return ScriptWorkbenchResult(edits: nil, content: empty, notes: notes, status: "The script failed. Nothing to keep.")
        }
        guard !response.outputs.isEmpty,
              let edits = ScriptEdits.replacements(fullText: fullText, selections: selections, response: response) else {
            return ScriptWorkbenchResult(edits: nil, content: empty, notes: notes, status: "The run gave no result.")
        }
        let content = DiffReviewContent.make(fullText: fullText, edits: edits, context: context)
        let status = content.isEmpty ? "The script ran and would change nothing." : content.summary.description
        return ScriptWorkbenchResult(edits: content.isEmpty ? nil : edits, content: content, notes: notes, status: status)
    }

    /// What the script runs on, in words, for the sheet's heading.
    public static func targetDescription(selections: [NSRange]) -> String {
        let ranges = selections.filter { $0.length > 0 }
        switch ranges.count {
        case 0: return "The whole note"
        case 1: return "The selection"
        default: return "\(ranges.count) selections"
        }
    }
}
