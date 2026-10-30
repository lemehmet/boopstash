import Foundation
import Testing
@testable import BoopstashCore

/// The tokenizer against IDs from the model's own (Hugging Face) tokenizer.
@Suite struct WordPieceTokenizerTests {
    static let vocabulary = try! String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/MiniLM/vocab.txt"), encoding: .utf8)
    let tokenizer = WordPieceTokenizer(vocabulary: vocabulary)

    func ids(_ text: String) -> [Int32] {
        let encoding = tokenizer.encode(text)
        return Array(encoding.ids.prefix { $0 != 0 })
    }

    @Test func matchesTheReferenceTokenizer() {
        #expect(ids("invoice") == [101, 1999, 6767, 6610, 102])
        #expect(ids("bill for March") == [101, 3021, 2005, 2233, 102])
        #expect(ids("Weekly signups by region") == [101, 4882, 3696, 22264, 2011, 2555, 102])
    }

    @Test func punctuationAndAccentsSplitAndFold() {
        // "café," → "cafe" and ","; "naïve!" → "naive" and "!".
        let cafe = ids("Café, naïve!")
        #expect(cafe.first == 101 && cafe.last == 102)
        #expect(cafe == ids("cafe , naive !"))
    }

    /// Hugging Face's tokenizer drops format characters inside words.
    @Test func formatCharactersAreDropped() {
        #expect(ids("in\u{200B}voice") == ids("invoice"))
        #expect(ids("\u{FEFF}bill for\u{200D} March") == [101, 3021, 2005, 2233, 102])
    }

    @Test func paddingAndMaskHaveTheModelsLength() {
        let encoding = tokenizer.encode("hello")
        #expect(encoding.ids.count == 128 && encoding.mask.count == 128)
        #expect(encoding.mask.prefix(3) == [1, 1, 1] && encoding.mask[3] == 0)
    }

    /// Chunked folding gives the same words as folding the text whole,
    /// across chunk boundaries (#164).
    @Test func chunkingDoesNotChangeTheWords() {
        let text = String(repeating: "Ünïcode, CAFÉ\u{200B}s 中文 tabs\tand-dashes! ", count: 200)
        let whole = text.lowercased().decomposedStringWithCanonicalMapping
        #expect(tokenizer.words(in: text) == tokenizer.words(in: whole))
        #expect(tokenizer.words(in: text).count > 1500)
    }

    /// A long run without a word break is one [UNK], found without folding
    /// all of it (#170 review).
    @Test func anUnbrokenRunIsOneUnknownQuickly() {
        let started = ContinuousClock.now
        #expect(ids(String(repeating: "a", count: 5_000_000)) == [101, 100, 102])
        #expect(ContinuousClock.now - started < .milliseconds(1500))
        #expect(ids(String(repeating: "b", count: 2000) + " invoice") == [101, 100, 1999, 6767, 6610, 102])
        #expect(ids(String(repeating: "c", count: 150) + ".invoice") == [101, 100, 1012, 1999, 6767, 6610, 102])
    }

    /// A huge note is encoded from its start only, quickly.
    @Test func hugeTextStopsEarly() {
        let huge = String(repeating: "word ", count: 1_000_000)
        let started = ContinuousClock.now
        let encoding = tokenizer.encode(huge)
        #expect(encoding.ids.count == 128 && encoding.ids.last == 102)
        #expect(ContinuousClock.now - started < .milliseconds(200))
    }

    @Test func longTextIsCutAtTheLength() {
        let encoding = tokenizer.encode(String(repeating: "word ", count: 500))
        #expect(encoding.ids.count == 128 && encoding.ids.last == 102 && !encoding.mask.contains(0))
    }
}
