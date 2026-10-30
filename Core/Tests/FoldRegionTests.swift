import Foundation
import Testing
@testable import BoopstashCore

/// Where the editor can fold (#155).
@Suite struct FoldRegionTests {
    func regions(_ text: String, _ language: SyntaxLanguage) async throws -> [FoldRegion] {
        let engine = try SyntaxEngine(language: language)
        _ = await engine.reset(text)
        return await engine.foldRegions()
    }

    @Test func jsonBlocksKeepTheirClosingLine() async throws {
        let json = """
            {
              "a": [
                1,
                2
              ],
              "b": 3
            }
            """
        let found = try await regions(json, .json)
        #expect(found.contains(FoldRegion(startLine: 0, hidden: 1...5, lastLine: 6)), "\(found)")
        #expect(found.contains(FoldRegion(startLine: 1, hidden: 2...3, lastLine: 4)), "\(found)")
    }

    /// Node.range is already UTF-16 (SwiftTreeSitter halves the UTF-16LE
    /// byte offsets), so text before the closer, accented or astral, does
    /// not shift the closer check (#167).
    @Test func nonASCIITextBeforeTheCloser() async throws {
        let found = try await regions("{\n  \"é🙂中\": \"ünïcødé 🙂🙂\"\n}\n", .json)
        #expect(found == [FoldRegion(startLine: 0, hidden: 1...1, lastLine: 2)], "\(found)")
    }

    /// A closing bracket after other text on its line hides with it.
    @Test func aCompactClosingLineFolds() async throws {
        let found = try await regions("{\n  \"a\": 1 }", .json)
        #expect(found == [FoldRegion(startLine: 0, hidden: 1...1)], "\(found)")
    }

    @Test func markdownSectionsFoldToTheNextHeading() async throws {
        let markdown = "# One\ntext\nmore\n# Two\nlast\n"
        let found = try await regions(markdown, .markdown)
        #expect(found.contains(FoldRegion(startLine: 0, hidden: 1...2)), "\(found)")
    }

    @Test func swiftBodiesFold() async throws {
        let swift = "func a() {\n    let x = 1\n    print(x)\n}\n"
        let found = try await regions(swift, .swift)
        #expect(found.contains(FoldRegion(startLine: 0, hidden: 1...2, lastLine: 3)), "\(found)")
    }

    /// A closing tag alone on the last line stays visible, as a bracket does.
    @Test func closingTagsStayVisible() async throws {
        let html = try await regions("<div>\ntext\n</div>\n", .html)
        #expect(html.contains(FoldRegion(startLine: 0, hidden: 1...1, lastLine: 2)), "\(html)")
        let xml = try await regions("<a>\n  <b/>\n</a>\n", .xml)
        #expect(xml.contains(FoldRegion(startLine: 0, hidden: 1...1, lastLine: 2)), "\(xml)")
    }

    @Test func plainTextFoldsByIndentation() {
        let text = "top\n  child\n\n  child\nnext\n"
        #expect(FoldRegions.byIndentation(text) == [FoldRegion(startLine: 0, hidden: 1...3)])
        #expect(FoldRegions.byIndentation("a\nb\n").isEmpty)
    }

    @Test func oneRegionPerLineTheWidest() {
        let regions = [FoldRegion(startLine: 0, hidden: 1...2), FoldRegion(startLine: 0, hidden: 1...5), FoldRegion(startLine: 2, hidden: 3...4)]
        #expect(FoldRegions.normalized(regions) == [FoldRegion(startLine: 0, hidden: 1...5), FoldRegion(startLine: 2, hidden: 3...4)])
    }
}
