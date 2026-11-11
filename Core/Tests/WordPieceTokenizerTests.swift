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
    /// all of it (#170 review). Checked by what reaches the word handler,
    /// not by a clock, which shared CI runners do not keep to (#220): the
    /// run is cut after `longWord` scalars and stands for itself as one
    /// over-long placeholder, so the 5,000,000 scalars are never one word.
    @Test func anUnbrokenRunIsCutNotFolded() {
        var words: [String] = []
        tokenizer.forEachWord(in: String(repeating: "b", count: 5_000_000)) { words.append($0); return true }
        #expect(words == [String(repeating: "a", count: WordPieceTokenizer.maxWordLength + 1)])
        #expect(ids(String(repeating: "a", count: 5_000_000)) == [101, 100, 102])
        #expect(ids(String(repeating: "b", count: 2000) + " invoice") == [101, 100, 1999, 6767, 6610, 102])
        #expect(ids(String(repeating: "c", count: 150) + ".invoice") == [101, 100, 1012, 1999, 6767, 6610, 102])
        // Characters folding removes do not make a word long.
        #expect(ids(String(repeating: "\u{200B}", count: 5000) + "invoice") == [101, 1999, 6767, 6610, 102])
        #expect(ids("in" + String(repeating: "\u{0301}", count: 2000) + "voice") == [101, 1999, 6767, 6610, 102])
    }

    /// The placeholder comes as soon as the run passes `longWord`, before
    /// the rest of it is read, so the tail is never folded (#227). Counting
    /// the scalars read pins this without a clock: building the placeholder
    /// only after reading the whole run gives the same words, but late.
    @Test func anUnbrokenRunIsCutBeforeItsTailIsRead() {
        var read = 0
        let run = (0..<100_000).lazy.map { _ -> Unicode.Scalar in read += 1; return "b" }
        var words: [String] = []
        var readAtFirstWord: Int?
        tokenizer.forEachWord(scalars: run) { word in
            if readAtFirstWord == nil { readAtFirstWord = read }
            words.append(word)
            return true
        }
        #expect(words == [String(repeating: "a", count: WordPieceTokenizer.maxWordLength + 1)])
        #expect(readAtFirstWord == WordPieceTokenizer.longWord + 1)
        #expect(read == 100_000)
    }

    /// Chunked folding (#164) is exact only because Swift's lowercased() maps
    /// each scalar on its own: no final-sigma rule, no other context. If that
    /// ever changes, chunks must be cut only where case has no context (#175).
    @Test func lowerCasingHasNoContext() {
        #expect("ΟΣ'".lowercased() == "οσ'" && "ΟΣ".lowercased() == "οσ")
        let text = String(repeating: "a", count: 1020) + " ΟΣ'Α ΟΣ"
        #expect(tokenizer.words(in: text) == tokenizer.words(in: text.lowercased()))
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
