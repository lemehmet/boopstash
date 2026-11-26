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
        for platform in HelpPage.Platform.allCases {
            #expect(HelpPage.markdown(from: nil, for: platform) == nil)
            #expect(HelpPage.markdown(from: Data(), for: platform) == nil)
            #expect(HelpPage.markdown(from: Data(" \n\n".utf8), for: platform) == nil)
            #expect(HelpPage.markdown(from: Data([0xFF, 0xFE, 0xFD]), for: platform) == nil, "not UTF-8")
            #expect(HelpPage.markdown(from: Data("# Title\n".utf8), for: platform) == "# Title\n")
        }
        // Nothing of the file is for the phone: no page, not a blank one.
        let macOnly = Data("<!-- help:mac -->\n# Install\n<!-- help:end -->\n".utf8)
        #expect(HelpPage.markdown(from: macOnly, for: .ios) == nil)
        #expect(HelpPage.markdown(from: macOnly, for: .mac) == "# Install\n")
    }

    // MARK: Parts for one platform (#263)

    static let marked = """
        # App

        For everyone.

        <!-- help:mac -->
        ## Install

        ```sh
        brew install app
        ```

        <!-- help:end -->

        ## Privacy

        Stays here.

        <!-- help:ios -->
        ## Share sheet

        <!-- help:end -->
        <!-- help:mac -->
        ## Building

        <!-- help:end -->
        ## License
        """

    /// The scenario of #263: on iOS the Mac's install, command-line and
    /// build parts are gone; on the Mac the page is the README without its
    /// marker lines.
    @Test func aPageLeavesOutThePartsMarkedForAnotherPlatform() {
        #expect(HelpPage.page(Self.marked, for: .ios) == """
            # App

            For everyone.


            ## Privacy

            Stays here.

            ## Share sheet

            ## License
            """)
        #expect(HelpPage.page(Self.marked, for: .mac) == """
            # App

            For everyone.

            ## Install

            ```sh
            brew install app
            ```


            ## Privacy

            Stays here.

            ## Building

            ## License
            """)
    }

    @Test func noPageShowsAMarkerAndTheMacsIsTheFileWithoutThem() {
        let lines = Self.marked.split(separator: "\n", omittingEmptySubsequences: false)
        let unmarked = lines.filter { !$0.hasPrefix("<!-- help:") }.joined(separator: "\n")
        #expect(HelpPage.page(unmarked, for: .mac) == unmarked, "a file without markers is its own page")
        #expect(HelpPage.page(unmarked, for: .ios) == unmarked)
        for platform in HelpPage.Platform.allCases {
            #expect(!HelpPage.page(Self.marked, for: platform).contains("help:"))
        }
    }

    @Test func aMarkerIsACommentAloneOnItsLine() {
        #expect(HelpPage.marker("<!-- help:mac -->") == .only(.mac))
        #expect(HelpPage.marker("  <!--help:ios-->  ") == .only(.ios))
        #expect(HelpPage.marker("<!-- help: end -->") == .end)
        #expect(HelpPage.marker("<!-- help:mac -->\r") == .only(.mac), "a file with Windows line ends")
        for line in ["<!-- help:windows -->", "<!-- note -->", "<!-- help:mac --> text", "text <!-- help:end -->",
                     "<!-- help:mac", "help:mac", "<!---->", "<!-->", ""] {
            #expect(HelpPage.marker(Substring(line)) == nil, "\(line)")
        }
        // What is no marker is a line of the page, on every platform.
        #expect(HelpPage.page("a\n<!-- help:windows -->\nb", for: .ios) == "a\n<!-- help:windows -->\nb")
        #expect(HelpPage.page("a\r\n<!-- help:mac -->\r\nb\r\n<!-- help:end -->\r\nc", for: .ios) == "a\nc")
    }

    @Test func aMarkerInsideAFenceIsCode() {
        let text = """
            Mark a part like this:

            ```html
            <!-- help:mac -->
            ```

            ~~~~
            ```
            <!-- help:end -->
            ~~~
            ~~~~
            after
            """
        #expect(HelpPage.page(text, for: .ios) == text)
        #expect(HelpPage.markersAreBalanced(text))
        // A fence inside a part goes with it, its closing line included.
        #expect(HelpPage.page("a\n<!-- help:mac -->\n```\ncode\n```\n<!-- help:end -->\nb", for: .ios) == "a\nb")
    }

    @Test func aPartThatIsNeverEndedRunsToTheEndAndPartsDoNotNest() {
        #expect(HelpPage.page("a\n<!-- help:mac -->\nb\nc", for: .ios) == "a")
        #expect(HelpPage.page("a\n<!-- help:mac -->\nb\nc", for: .mac) == "a\nb\nc")
        // The second part takes over from the first; one end ends it.
        let nested = "a\n<!-- help:mac -->\nb\n<!-- help:ios -->\nc\n<!-- help:end -->\nd\n<!-- help:end -->\ne"
        #expect(HelpPage.page(nested, for: .mac) == "a\nb\nd\ne")
        #expect(HelpPage.page(nested, for: .ios) == "a\nc\nd\ne")
        #expect(HelpPage.page("<!-- help:end -->\na", for: .ios) == "a", "an end with nothing to end")
    }

    @Test func balanceIsWhatTheREADMEIsHeldTo() {
        #expect(HelpPage.markersAreBalanced(Self.marked))
        #expect(HelpPage.markersAreBalanced("no markers"))
        #expect(!HelpPage.markersAreBalanced("<!-- help:mac -->\nnever ended"))
        #expect(!HelpPage.markersAreBalanced("<!-- help:end -->"))
        #expect(!HelpPage.markersAreBalanced("<!-- help:mac -->\n<!-- help:ios -->\n<!-- help:end -->"))
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
    static func readme() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("README.md"))
    }

    /// The README's marks (#263), checked for their shape and not for what
    /// they enclose: every part is ended, no page shows a mark (the preview
    /// would draw the comment as written), the Mac's page is the whole file
    /// but for its marker lines, and the phone's has something left.
    @Test func theRepositorysREADMEMarksItsPartsSoundly() async throws {
        let text = try #require(String(data: try Self.readme(), encoding: .utf8))
        #expect(HelpPage.markersAreBalanced(text))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let mac = try #require(HelpPage.markdown(from: Data(text.utf8), for: .mac))
        #expect(mac == lines.filter { HelpPage.marker($0) == nil }.joined(separator: "\n"))
        let ios = try #require(HelpPage.markdown(from: Data(text.utf8), for: .ios))
        for page in [mac, ios] {
            let out = await MarkdownPreview.blocks(for: page, linkBase: HelpPage.linkBase)
            #expect(out.contains { if case .heading = $0 { true } else { false } })
            #expect(!out.contains { if case .rawHTML(let html) = $0 { html.contains("help:") } else { false } })
        }
        // A part for the Mac alone is not on the phone's page.
        if lines.contains(where: { HelpPage.marker($0) == .only(.mac) }) { #expect(ios.count < mac.count) }
    }

    @Test(arguments: HelpPage.Platform.allCases)
    func theRepositorysREADMERendersWithNothingToLoad(on platform: HelpPage.Platform) async throws {
        let markdown = try #require(HelpPage.markdown(from: try Self.readme(), for: platform))
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
