import Foundation
import Testing
@testable import BoopstashCore

/// Help (#254): the README as the preview draws it. The preview has no
/// block that loads anything, so what is checked here is what a page may
/// carry: pictures that are only named, and links to the web or by mail.
@Suite struct HelpPageTests {
    func plain(_ text: AttributedString) -> String { String(text.characters) }

    /// Every run of inline text in the blocks, nested ones included.
    static func texts(in blocks: [PreviewBlock]) -> [AttributedString] {
        blocks.flatMap { block -> [AttributedString] in
            switch block {
            case .heading(_, let text), .paragraph(let text): [text]
            case .quote(let inner): texts(in: inner)
            case .list(_, _, let items): items.flatMap { texts(in: $0.blocks) }
            case .table(let header, let rows, _): header + rows.flatMap { $0 }
            case .code, .rule, .image, .rawHTML: []
            }
        }
    }

    static func images(in blocks: [PreviewBlock]) -> [PreviewImage] {
        blocks.flatMap { block -> [PreviewImage] in
            switch block {
            case .image(let image): [image]
            case .quote(let inner): images(in: inner)
            case .list(_, _, let items): items.flatMap { images(in: $0.blocks) }
            default: []
            }
        }
    }

    static func links(in blocks: [PreviewBlock]) -> [URL] {
        texts(in: blocks).flatMap { $0.runs.compactMap(\.link) }
    }

    // MARK: The file

    @Test func aMissingUnreadableOrBlankFileIsNoPage() {
        #expect(HelpPage.markdown(from: nil) == nil)
        #expect(HelpPage.markdown(from: Data()) == nil)
        #expect(HelpPage.markdown(from: Data(" \n\n".utf8)) == nil)
        #expect(HelpPage.markdown(from: Data([0xFF, 0xFE, 0xFD])) == nil, "not UTF-8")
        #expect(HelpPage.markdown(from: Data("# Title\n".utf8)) == "# Title\n")
    }

    // MARK: Links

    @Test func relativeLinksLeadToTheRepository() async {
        let out = await MarkdownPreview.blocks(
            for: "[plan](docs/plan/milestones.md) [adr](docs/adr/) [`SECURITY.md`](SECURITY.md) [web](https://brew.sh)",
            linkBase: HelpPage.linkBase)
        #expect(Self.links(in: out).map(\.absoluteString) == [
            "https://github.com/lemehmet/boopstash/blob/main/docs/plan/milestones.md",
            "https://github.com/lemehmet/boopstash/blob/main/docs/adr/",
            "https://github.com/lemehmet/boopstash/blob/main/SECURITY.md",
            "https://brew.sh",
        ])
    }

    @Test func aBaseMakesNothingUnsafeALink() async {
        let out = await MarkdownPreview.blocks(
            for: "[js](javascript:alert(1)) [file](file:///etc/hosts) [anchor](#install) [other](//other.test/x) [mail](mailto:a@b.test)",
            linkBase: HelpPage.linkBase)
        #expect(Self.links(in: out).map(\.absoluteString) == ["mailto:a@b.test"])
        guard case .paragraph(let text) = out.first else {
            Issue.record("\(out)")
            return
        }
        #expect(plain(text) == "js file anchor other mail", "a link that is refused keeps its text")
    }

    @Test func aNotesRelativeLinksStayText() async {
        let out = await MarkdownPreview.blocks(for: "[plan](docs/plan/milestones.md) [web](https://brew.sh)")
        #expect(Self.links(in: out).map(\.absoluteString) == ["https://brew.sh"])
        #expect(MarkdownPreview.safeLink("LICENSE") == nil)
        #expect(MarkdownPreview.safeLink("LICENSE", relativeTo: HelpPage.linkBase)?.absoluteString
            == "https://github.com/lemehmet/boopstash/blob/main/LICENSE")
    }

    // MARK: Pictures

    /// A badge or a screenshot the README may gain is named, never loaded,
    /// whether its address is remote or a file of the repository.
    @Test func badgesAndPicturesDegradeToTheirText() async {
        let out = await MarkdownPreview.blocks(
            for: "[![CI](https://ci.test/badge.svg)](https://ci.test/runs) ![shot](docs/shot.png)\n\n<img src=\"https://x.test/a.png\">\n",
            linkBase: HelpPage.linkBase)
        #expect(Self.images(in: out) == [
            .blocked(source: "https://ci.test/badge.svg", alt: "CI"),
            .blocked(source: "docs/shot.png", alt: "shot"),
        ])
        #expect(out.contains(.rawHTML("<img src=\"https://x.test/a.png\">\n")), "HTML is shown as written")
    }

    // MARK: The repository's README

    /// The file both apps bundle. Checked for what any README must satisfy,
    /// not for what this one says, so editing it needs no other change.
    @Test func theRepositorysREADMERendersWithNothingToLoad() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("README.md")
        let markdown = try #require(HelpPage.markdown(from: try Data(contentsOf: url)))
        let out = await MarkdownPreview.blocks(for: markdown, linkBase: HelpPage.linkBase)
        #expect(out.contains { if case .heading = $0 { true } else { false } })
        for image in Self.images(in: out) {
            guard case .blocked = image else {
                Issue.record("the README has no attachments: \(image)")
                continue
            }
        }
        let links = Self.links(in: out)
        #expect(!links.isEmpty)
        for link in links {
            #expect(["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? ""), "\(link)")
        }
    }
}
