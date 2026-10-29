import Foundation

/// Pretty-prints JSON without round-tripping it through a parser that
/// rebuilds values: numbers, string escapes and key order come out exactly
/// as written (`1e400`, `0.10000000000000001`, `"é"`), only the
/// whitespace between tokens changes. Optionally sorts object keys.
public enum JSONFormatter {
    public static func format(_ text: String, indent: Int = 2, sortKeys: Bool = false) -> Result<String, FormatError> {
        var parser = Parser(text)
        do {
            let value = try parser.document()
            var out = ""
            var written = 0
            try write(value, into: &out, depth: 0, indent: String(repeating: " ", count: indent), sortKeys: sortKeys, written: &written)
            return .success(out + "\n")
        } catch let error as FormatError {
            return .failure(error)
        } catch {
            return .failure(FormatError(message: "\(error)", line: nil, column: nil))
        }
    }

    indirect enum Value {
        case object([(key: String, value: Value)])
        case array([Value])
        /// A string, number or literal, exactly as it was written.
        case scalar(String)
    }

    /// Values written between checks for cancellation (#98).
    static let checkEvery = 4096

    static func write(_ value: Value, into out: inout String, depth: Int, indent: String, sortKeys: Bool, written: inout Int) throws {
        written += 1
        if written % checkEvery == 0, Task.isCancelled { throw FormatError.cancelled }
        let pad = String(repeating: indent, count: depth + 1)
        let closing = String(repeating: indent, count: depth)
        switch value {
        case .scalar(let raw):
            out += raw
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                try write(item, into: &out, depth: depth + 1, indent: indent, sortKeys: sortKeys, written: &written)
                out += index < items.count - 1 ? ",\n" : "\n"
            }
            out += closing + "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            let ordered = sortKeys ? members.sorted { decoded($0.key) < decoded($1.key) } : members
            out += "{\n"
            for (index, member) in ordered.enumerated() {
                out += pad + member.key + ": "
                try write(member.value, into: &out, depth: depth + 1, indent: indent, sortKeys: sortKeys, written: &written)
                out += index < ordered.count - 1 ? ",\n" : "\n"
            }
            out += closing + "}"
        }
    }

    /// A key's text for sorting: its escapes resolved, so `"a"` sorts
    /// as `a`.
    static func decoded(_ raw: String) -> String {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String ?? raw
    }

    /// A strict RFC 8259 reader over UTF-8 bytes that keeps each scalar's
    /// source text.
    /// Deeper documents are refused rather than parsed: parsing and writing
    /// recurse once per level. 512 levels overflowed the small stacks that
    /// test threads get in debug builds; 256 leaves room on any thread.
    static let maxDepth = 256

    struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0
        /// Where the next check for cancellation is due.
        var nextCheck = 1 << 16

        init(_ text: String) { bytes = Array(text.utf8) }

        mutating func document() throws -> Value {
            try skipWhitespace()
            // A leading byte-order mark is not JSON, but editors leave one.
            if bytes[index...].starts(with: [0xEF, 0xBB, 0xBF]) { index += 3; try skipWhitespace() }
            let value = try self.value()
            try skipWhitespace()
            guard index == bytes.count else { throw failure("unexpected text after the JSON value") }
            return value
        }

        mutating func value() throws -> Value {
            // A superseded format stops here rather than parsing on.
            if Task.isCancelled { throw FormatError.cancelled }
            guard index < bytes.count else { throw failure("the JSON ends early") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .scalar(try string())
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .scalar(try number())
            case UInt8(ascii: "t"): return .scalar(try literal("true"))
            case UInt8(ascii: "f"): return .scalar(try literal("false"))
            case UInt8(ascii: "n"): return .scalar(try literal("null"))
            default: throw failure("expected a value")
            }
        }

        mutating func object() throws -> Value {
            try descend()
            defer { depth -= 1 }
            index += 1
            var members: [(key: String, value: Value)] = []
            try skipWhitespace()
            if peek("}") { index += 1; return .object(members) }
            while true {
                try skipWhitespace()
                guard peek("\"") else { throw failure("expected a quoted key") }
                let key = try string()
                try skipWhitespace()
                guard peek(":") else { throw failure("expected ':' after the key") }
                index += 1
                try skipWhitespace()
                members.append((key, try value()))
                try skipWhitespace()
                if peek(",") { index += 1; continue }
                if peek("}") { index += 1; return .object(members) }
                throw failure("expected ',' or '}'")
            }
        }

        mutating func array() throws -> Value {
            try descend()
            defer { depth -= 1 }
            index += 1
            var items: [Value] = []
            try skipWhitespace()
            if peek("]") { index += 1; return .array(items) }
            while true {
                try skipWhitespace()
                items.append(try value())
                try skipWhitespace()
                if peek(",") { index += 1; continue }
                if peek("]") { index += 1; return .array(items) }
                throw failure("expected ',' or ']'")
            }
        }

        mutating func descend() throws {
            depth += 1
            guard depth <= JSONFormatter.maxDepth else {
                throw failure("nested deeper than \(JSONFormatter.maxDepth) levels")
            }
        }

        mutating func string() throws -> String {
            let start = index
            index += 1
            while index < bytes.count {
                // A multi-megabyte string stops part way when superseded.
                try checkCancellation()
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    index += 1
                    return String(decoding: bytes[start..<index], as: UTF8.self)
                case UInt8(ascii: "\\"):
                    index += 1
                    guard index < bytes.count else { break }
                    switch bytes[index] {
                    case UInt8(ascii: "u"):
                        let hex = bytes[(index + 1)..<min(index + 5, bytes.count)]
                        guard hex.count == 4, hex.allSatisfy({ isHexDigit($0) }) else { throw failure("bad \\u escape") }
                        index += 5
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                         UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                        index += 1
                    default:
                        throw failure("bad escape in a string")
                    }
                case 0x00...0x1F:
                    throw failure("a control character inside a string must be escaped")
                default:
                    index += 1
                }
            }
            index = start
            throw failure("unterminated string")
        }

        mutating func number() throws -> String {
            let start = index
            if peek("-") { index += 1 }
            if peek("0") {
                index += 1
            } else if try digits() == 0 {
                throw failure("expected a digit")
            }
            if peek(".") {
                index += 1
                guard try digits() > 0 else { throw failure("expected a digit after '.'") }
            }
            if peek("e") || peek("E") {
                index += 1
                if peek("+") || peek("-") { index += 1 }
                guard try digits() > 0 else { throw failure("expected a digit in the exponent") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func literal(_ word: String) throws -> String {
            guard bytes[index...].starts(with: Array(word.utf8)) else { throw failure("expected a value") }
            index += word.utf8.count
            return word
        }

        @discardableResult
        mutating func digits() throws -> Int {
            let start = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
                try checkCancellation()
            }
            return index - start
        }

        mutating func skipWhitespace() throws {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
                try checkCancellation()
            }
        }

        /// Every 64 KiB of input, whether the format was superseded (#98):
        /// a check per byte would cost more than the scan. Due once that much
        /// has been passed, however far each step moves (escapes are two to
        /// six bytes).
        mutating func checkCancellation() throws {
            guard index >= nextCheck else { return }
            nextCheck = index + (1 << 16)
            if Task.isCancelled { throw FormatError.cancelled }
        }

        func peek(_ character: Unicode.Scalar) -> Bool {
            index < bytes.count && bytes[index] == UInt8(ascii: character)
        }

        func isHexDigit(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }

        /// The error, placed at the current position (1-based line and column,
        /// columns in characters).
        func failure(_ message: String) -> FormatError {
            let before = bytes[..<min(index, bytes.count)]
            let line = before.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
            let lineStart = before.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            let column = String(decoding: bytes[lineStart..<min(index, bytes.count)], as: UTF8.self).count + 1
            return FormatError(message: message, line: line, column: column)
        }
    }
}
