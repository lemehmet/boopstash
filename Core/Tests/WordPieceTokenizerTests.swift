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

    @Test func paddingAndMaskHaveTheModelsLength() {
        let encoding = tokenizer.encode("hello")
        #expect(encoding.ids.count == 128 && encoding.mask.count == 128)
        #expect(encoding.mask.prefix(3) == [1, 1, 1] && encoding.mask[3] == 0)
    }

    @Test func longTextIsCutAtTheLength() {
        let encoding = tokenizer.encode(String(repeating: "word ", count: 500))
        #expect(encoding.ids.count == 128 && encoding.ids.last == 102 && !encoding.mask.contains(0))
    }
}
