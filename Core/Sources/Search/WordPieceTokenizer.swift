import Foundation

/// BERT's uncased WordPiece tokenizer, as all-MiniLM-L6-v2 was trained with
/// (#157): lower-cased, accents removed, split on whitespace and
/// punctuation, then each word into the longest pieces in the vocabulary.
/// Gives the model's input: [CLS] pieces [SEP], padded to `length`, with
/// its attention mask.
public struct WordPieceTokenizer: Sendable {
    public let length: Int
    let ids: [String: Int32]
    let unknown: Int32, start: Int32, end: Int32, padding: Int32

    /// `vocabulary` is vocab.txt: one piece per line, its ID its line number.
    public init(vocabulary: String, length: Int = 128) {
        var ids: [String: Int32] = [:]
        for (index, line) in vocabulary.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.isEmpty {
            ids[String(line)] = Int32(index)
        }
        self.ids = ids
        self.length = length
        unknown = ids["[UNK]"] ?? 100
        start = ids["[CLS]"] ?? 101
        end = ids["[SEP]"] ?? 102
        padding = ids["[PAD]"] ?? 0
    }

    public struct Encoding: Equatable, Sendable {
        public var ids: [Int32]
        public var mask: [Int32]
    }

    public func encode(_ text: String) -> Encoding {
        var pieces: [Int32] = [start]
        // Words are made only until the pieces are filled: a 5 MB note
        // costs its first few hundred words, not millions (#164).
        forEachWord(in: text) { word in
            for piece in self.pieces(of: word) {
                guard pieces.count < length - 1 else { break }
                pieces.append(piece)
            }
            return pieces.count < length - 1
        }
        pieces.append(end)
        let used = pieces.count
        pieces += Array(repeating: padding, count: length - used)
        return Encoding(ids: pieces, mask: Array(repeating: 1, count: used) + Array(repeating: 0, count: length - used))
    }

    /// Lower-cased, accents removed, control and format characters dropped, split on
    /// whitespace, with each punctuation mark and CJK character on its own.
    func words(in text: String) -> [String] {
        var words: [String] = []
        forEachWord(in: text) { words.append($0); return true }
        return words
    }

    /// The words of `words(in:)`, one at a time, until `body` returns false.
    /// The text is folded (lower-cased, decomposed) a chunk at a time, each
    /// ending at whitespace, so stopping early skips the rest; whitespace
    /// ends words anyway, so the words are the same as folding it whole.
    func forEachWord(in text: String, _ body: (String) -> Bool) {
        var chunk = String.UnicodeScalarView()
        var stopped = false
        func process() {
            let folded = String(chunk).lowercased().decomposedStringWithCanonicalMapping
            chunk = String.UnicodeScalarView()
            var current = String.UnicodeScalarView()
            func flush() -> Bool {
                defer { current = String.UnicodeScalarView() }
                return current.isEmpty || body(String(current))
            }
            for scalar in folded.unicodeScalars {
                let properties = scalar.properties
                if properties.generalCategory == .nonspacingMark { continue }
                // BERT drops control and format characters (zero-width space,
                // joiners, the BOM) before splitting.
                if scalar.value == 0 || scalar.value == 0xFFFD || properties.generalCategory == .format
                    || (properties.generalCategory == .control && !properties.isWhitespace) { continue }
                if properties.isWhitespace {
                    guard flush() else { stopped = true; return }
                } else if Self.isPunctuation(scalar) || Self.isCJK(scalar) {
                    guard flush(), body(String(scalar)) else { stopped = true; return }
                } else {
                    current.append(scalar)
                }
            }
            if !flush() { stopped = true }
        }
        for scalar in text.unicodeScalars {
            chunk.append(scalar)
            if chunk.count >= 1024, scalar.properties.isWhitespace {
                process()
                if stopped { return }
            }
        }
        if !chunk.isEmpty { process() }
    }

    /// The longest pieces from the start, later ones prefixed "##"; a word
    /// with no such split, or over 100 characters, is [UNK].
    func pieces(of word: String) -> [Int32] {
        let characters = Array(word.unicodeScalars)
        guard characters.count <= 100 else { return [unknown] }
        var result: [Int32] = []
        var startIndex = 0
        while startIndex < characters.count {
            var endIndex = characters.count
            var found: Int32?
            while startIndex < endIndex {
                var piece = String(String.UnicodeScalarView(characters[startIndex..<endIndex]))
                if startIndex > 0 { piece = "##" + piece }
                if let id = ids[piece] {
                    found = id
                    break
                }
                endIndex -= 1
            }
            guard let found else { return [unknown] }
            result.append(found)
            startIndex = endIndex
        }
        return result
    }

    /// BERT's punctuation: ASCII symbols as well as Unicode's P categories.
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if (33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value) || (123...126).contains(value) { return true }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2B73F).contains(value) || (0x2B740...0x2B81F).contains(value) || (0x2B820...0x2CEAF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0x2F800...0x2FA1F).contains(value)
    }
}
