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
        #expect(found.contains(FoldRegion(startLine: 0, hidden: 1...5)), "\(found)")
        #expect(found.contains(FoldRegion(startLine: 1, hidden: 2...3)), "\(found)")
    }

    @Test func markdownSectionsFoldToTheNextHeading() async throws {
        let markdown = "# One\ntext\nmore\n# Two\nlast\n"
        let found = try await regions(markdown, .markdown)
        #expect(found.contains(FoldRegion(startLine: 0, hidden: 1...2)), "\(found)")
    }

    @Test func swiftBodiesFold() async throws {
        let swift = "func a() {\n    let x = 1\n    print(x)\n}\n"
        let found = try await regions(swift, .swift)
        #expect(found.contains(FoldRegion(startLine: 0, hidden: 1...2)), "\(found)")
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
