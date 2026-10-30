import Foundation

/// Formatting by JavaScript formatters in the script service (ADR 0005,
/// ADR 0007): Prettier for web languages, YAML and Markdown (#56), and
/// sql-formatter for SQL (#57). Core decides which formatter and options;
/// the service only runs them.
public struct JSFormatRequest: Codable, Sendable, Equatable {
    public enum Engine: String, Codable, Sendable {
        case prettier
        case sqlFormatter
        /// Formatters compiled to WebAssembly (#158, ADR 0010).
        case ruff, gofmt, shfmt, clangFormat
    }

    public var engine: Engine
    public var source: String
    /// The formatter's options as JSON: Prettier's `parser`, `tabWidth`,
    /// `singleQuote`; sql-formatter's `language`, `keywordCase`, `tabWidth`.
    public var options: String
    /// Seconds before the service gives up; loading Prettier the first time
    /// takes part of it.
    public var timeLimit: Double

    public init(engine: Engine, source: String, options: String, timeLimit: Double = 5) {
        self.engine = engine
        self.source = source
        self.options = options
        self.timeLimit = timeLimit
    }
}

public struct JSFormatResponse: Codable, Sendable, Equatable {
    public var formatted: String?
    public var error: FormatError?

    public init(formatted: String? = nil, error: FormatError? = nil) {
        self.formatted = formatted
        self.error = error
    }
}

/// The options Settings ▸ Editor exposes for formatting.
public struct FormatSettings: Codable, Sendable, Equatable {
    public enum KeywordCase: String, Codable, CaseIterable, Sendable {
        case preserve, upper, lower
    }

    /// sql-formatter's dialect names.
    public static let sqlDialects: [(id: String, name: String)] = [
        ("sql", "Standard SQL"), ("postgresql", "PostgreSQL"), ("mysql", "MySQL"),
        ("sqlite", "SQLite"), ("transactsql", "Transact-SQL"),
    ]

    public var tabWidth: Int
    public var singleQuote: Bool
    public var sqlDialect: String
    public var keywordCase: KeywordCase

    public init(tabWidth: Int = 2, singleQuote: Bool = false, sqlDialect: String = "sql", keywordCase: KeywordCase = .preserve) {
        self.tabWidth = min(max(tabWidth, 1), 8)
        self.singleQuote = singleQuote
        self.sqlDialect = Self.sqlDialects.contains { $0.id == sqlDialect } ? sqlDialect : "sql"
        self.keywordCase = keywordCase
    }
}

public enum JSFormatting {
    /// Prettier's parser for a language, when Prettier formats it.
    public static func prettierParser(for language: SyntaxLanguage?) -> String? {
        switch language {
        case .javascript: "babel"
        case .typescript: "typescript"
        case .css: "css"
        case .html: "html"
        case .yaml: "yaml"
        case .markdown: "markdown"
        default: nil
        }
    }

    /// The WebAssembly formatter for a language (#158, ADR 0010).
    public static func wasmEngine(for language: SyntaxLanguage?) -> JSFormatRequest.Engine? {
        switch language {
        case .python: .ruff
        case .go: .gofmt
        case .bash: .shfmt
        case .c, .cpp, .java: .clangFormat
        default: nil
        }
    }

    public static func supports(_ language: SyntaxLanguage?) -> Bool {
        language == .sql || prettierParser(for: language) != nil || wasmEngine(for: language) != nil
    }

    /// The request that formats `source` as `language`, or nil when no
    /// JavaScript formatter handles it.
    public static func request(for source: String, as language: SyntaxLanguage?, settings: FormatSettings = FormatSettings()) -> JSFormatRequest? {
        let options: [String: Any]
        let engine: JSFormatRequest.Engine
        if language == .sql {
            engine = .sqlFormatter
            options = ["language": settings.sqlDialect, "keywordCase": settings.keywordCase.rawValue, "tabWidth": settings.tabWidth]
        } else if let parser = prettierParser(for: language) {
            engine = .prettier
            options = ["parser": parser, "tabWidth": settings.tabWidth, "singleQuote": settings.singleQuote]
        } else if let wasm = wasmEngine(for: language) {
            engine = wasm
            switch wasm {
            case .ruff:
                // PEP 8's four spaces whatever the width setting: Python
                // indented by two reads as foreign.
                options = ["indent_width": 4, "quote_style": settings.singleQuote ? "single" : "double"]
            case .shfmt:
                options = ["indent": settings.tabWidth]
            case .clangFormat:
                // The file name tells clang-format the language.
                let name = language == .c ? "note.c" : language == .java ? "Note.java" : "note.cpp"
                options = ["style": "{BasedOnStyle: LLVM, IndentWidth: \(settings.tabWidth)}", "filename": name]
            default:
                // gofmt has one style: tabs.
                options = [:]
            }
        } else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]) else { return nil }
        return JSFormatRequest(engine: engine, source: source, options: String(decoding: data, as: UTF8.self))
    }
}
