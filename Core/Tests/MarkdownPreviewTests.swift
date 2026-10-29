import Foundation
import Testing
@testable import BoopstashCore

@Suite struct MarkdownPreviewTests {
    func blocks(_ markdown: String) async -> [PreviewBlock] {
        await MarkdownPreview.blocks(for: markdown)
    }

    func plain(_ text: AttributedString) -> String { String(text.characters) }

    @Test func headingsParagraphsQuotesAndRules() async {
        let out = await blocks("# Title\n\nSome *em* and **strong** and `code`.\n\n> quoted\n\n---\n")
        guard out.count == 4, case .heading(1, let title) = out[0], case .paragraph(let body) = out[1],
              case .quote(let quoted) = out[2], case .rule = out[3] else {
            Issue.record("\(out)")
            return
        }
        #expect(plain(title) == "Title")
        #expect(plain(body) == "Some em and strong and code.")
        let em = body.runs.first { $0.inlinePresentationIntent == .emphasized }
        let strong = body.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized }
        let code = body.runs.first { $0.inlinePresentationIntent == .code }
        #expect(em.map { plain(AttributedString(body[$0.range])) } == "em")
        #expect(strong.map { plain(AttributedString(body[$0.range])) } == "strong")
        #expect(code.map { plain(AttributedString(body[$0.range])) } == "code")
        #expect(quoted.count == 1)
    }

    @Test func githubTablesTasksAndStrikethrough() async {
        let out = await blocks("| a | b |\n|:--|--:|\n| 1 | 2 |\n\n- [x] done\n- [ ] todo\n\n~~gone~~")
        guard case .table(let header, let rows, let alignments) = out[0] else {
            Issue.record("\(out)")
            return
        }
        #expect(header.map(plain) == ["a", "b"])
        #expect(rows.map { $0.map(plain) } == [["1", "2"]])
        #expect(alignments == [.leading, .trailing])
        guard case .list(false, _, let items) = out[1] else {
            Issue.record("\(out)")
            return
        }
        #expect(items.map(\.checked) == [true, false])
        guard case .paragraph(let gone) = out[2] else { return }
        #expect(gone.runs.first?.inlinePresentationIntent == .strikethrough)
    }

    /// The note's own HTML is text: nothing in it is interpreted.
    @Test func rawHTMLIsText() async {
        let out = await blocks("<script>alert(1)</script>\n\ninline <b>bold</b> here")
        #expect(out.first == .rawHTML("<script>alert(1)</script>\n"))
        guard case .paragraph(let text) = out.last else { return }
        #expect(plain(text) == "inline <b>bold</b> here")
    }

    @Test func imagesAreAttachmentsOrBlocked() async {
        let id = UUID()
        let out = await blocks("See ![chart](https://example.com/c.png) and ![local](attachment:\(id.uuidString.lowercased()))")
        #expect(out.contains(.image(.blocked(source: "https://example.com/c.png", alt: "chart"))))
        #expect(out.contains(.image(.attachment(id, alt: "local"))))
        guard case .paragraph(let text) = out.first else { return }
        #expect(plain(text) == "See  and ", "images leave the paragraph for blocks of their own")
    }

    @Test func imagesInsideLinksAndEmphasisAreKept() async {
        let id = UUID()
        let out = await blocks("[![badge](attachment:\(id.uuidString.lowercased()))](https://example.com) *![x](https://e.test/x.png)*")
        #expect(out.contains(.image(.attachment(id, alt: "badge"))))
        #expect(out.contains(.image(.blocked(source: "https://e.test/x.png", alt: "x"))))
    }

    @Test func onlySafeLinksStayLinks() async {
        let out = await blocks("[web](https://x.test/a?b=1) [mail](mailto:a@b.test) [bad](javascript:alert(1)) [file](file:///etc/hosts)")
        guard case .paragraph(let text) = out.first else { return }
        let links = text.runs.compactMap(\.link)
        #expect(links.map(\.absoluteString) == ["https://x.test/a?b=1", "mailto:a@b.test"])
        #expect(plain(text).contains("bad") && plain(text).contains("file"))
    }

    @Test func fencedCodeIsHighlightedEvenInsideLists() async {
        let out = await blocks("```swift\nlet a = 1\n```\n\n- item\n\n  ```json\n  {\"k\": 2}\n  ```\n\n```unknown\nplain\n```")
        guard case .code("swift", "let a = 1\n", let highlights) = out[0] else {
            Issue.record("\(out)")
            return
        }
        #expect(highlights.contains { $0.role == .keyword && $0.range == NSRange(location: 0, length: 3) })
        guard case .list(_, _, let items) = out[1], case .code("json", _, let nested) = items[0].blocks.last else {
            Issue.record("\(out)")
            return
        }
        #expect(!nested.isEmpty, "a code block inside a list is highlighted too")
        guard case .code("unknown", "plain\n", let none) = out[2] else { return }
        #expect(none.isEmpty)
    }

    @Test func fenceNamesAndAliases() {
        #expect(SyntaxLanguage(fenceName: "ts") == .typescript)
        #expect(SyntaxLanguage(fenceName: "json") == .json)
        #expect(SyntaxLanguage(fenceName: "brainfuck") == nil)
    }
}
