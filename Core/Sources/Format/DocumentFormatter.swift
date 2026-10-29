import Foundation

/// Why text could not be formatted, with where when the formatter knows.
public struct FormatError: Error, Equatable, Sendable {
    public var message: String
    public var line: Int?
    public var column: Int?

    public init(message: String, line: Int?, column: Int?) {
        self.message = message
        self.line = line
        self.column = column
    }

    /// For the window's banner: "Line 3, column 7: expected ',' or '}'".
    public var description: String {
        guard let line else { return message }
        return "Line \(line)\(column.map { ", column \($0)" } ?? ""): \(message)"
    }
}

/// Edit ▸ Format Document (ADR 0005): picks a formatter by the note's
/// language. Native formatters for JSON, XML and property lists live here;
/// Prettier and SQL come with the JavaScriptCore runtime.
public enum DocumentFormatter {
    public enum Style: Sendable {
        case standard
        /// JSON only: object keys in order.
        case sortedKeys
    }

    /// Whether `language` has a native formatter.
    public static func canFormat(_ language: SyntaxLanguage?, style: Style = .standard) -> Bool {
        switch (language, style) {
        case (.json, _): true
        case (.xml, .standard): XMLFormatter.isAvailable
        default: false
        }
    }

    public static func format(_ text: String, as language: SyntaxLanguage?, style: Style = .standard) -> Result<String, FormatError> {
        switch (language, style) {
        case (.json, .standard): JSONFormatter.format(text)
        case (.json, .sortedKeys): JSONFormatter.format(text, sortKeys: true)
        case (.xml, .standard): XMLFormatter.format(text)
        default: .failure(FormatError(message: "No formatter for \(language?.displayName ?? "plain text")", line: nil, column: nil))
        }
    }

    /// Where the caret belongs after reformatting: on the same
    /// non-whitespace character it was before (formatters change only
    /// whitespace, or here, where they do more, close to it). Offsets are
    /// UTF-16, as the editor's are.
    public static func caret(_ offset: Int, from original: String, to formatted: String) -> Int {
        let before = original.utf16.prefix(offset)
        // A byte-order mark is dropped by the JSON formatter, so it never
        // counts, on either side.
        func isSignificant(_ scalar: Unicode.Scalar) -> Bool { !scalar.properties.isWhitespace && scalar != "\u{FEFF}" }
        let significant = String(decoding: Array(before), as: UTF16.self).unicodeScalars.filter(isSignificant).count
        // Just before the next significant character: past the whitespace
        // the formatter put after the last one counted.
        var seen = 0
        var position = 0
        for scalar in formatted.unicodeScalars {
            if isSignificant(scalar) {
                if seen == significant { break }
                seen += 1
            }
            position += scalar.utf16.count
        }
        return min(position, formatted.utf16.count)
    }
}
