import Foundation
import Testing
@testable import BoopstashCore

@Suite struct HTMLToMarkdownTests {
    func md(_ html: String) -> String { HTMLToMarkdown.convert(html) }

    @Test func headingsAndParagraphs() {
        #expect(md("<h1>Title</h1><p>One   two\nthree.</p><h3>Sub</h3><p>Next</p>")
            == "# Title\n\nOne two three.\n\n### Sub\n\nNext")
    }

    @Test func emphasisHugsItsText() {
        #expect(md("<p>a <b> bold </b> and <em>it</em> and <del>gone</del></p>") == "a  **bold**  and *it* and ~~gone~~")
        #expect(md("<p><strong></strong>x</p>") == "x")
    }

    @Test func linksAndBareURLs() {
        #expect(md(#"<a href="https://x.y/a b">the docs</a>"#) == "[the docs](https://x.y/a%20b)")
        #expect(md(#"<a href="https://x.y">https://x.y</a>"#) == "<https://x.y>")
        #expect(md(#"<a href="javascript:alert(1)">click</a>"#) == "click")
        #expect(md(##"<a href="#section">jump</a>"##) == "jump")
    }

    @Test func destinationsCannotEndEarly() {
        #expect(md(#"<a href="https://x.test/a)b">x</a>"#) == "[x](https://x.test/a%29b)")
        #expect(md(#"<a href="https://x.test/wiki/Foo_(bar)">Foo</a>"#) == "[Foo](https://x.test/wiki/Foo_%28bar%29)")
        #expect(md(#"<img src="https://x.test/a b).png" alt="pic">"#) == "![pic](https://x.test/a%20b%29.png)")
        #expect(md(#"<a href="https://x.test/a<b>c">x</a>"#) == "[x](https://x.test/a%3Cb%3Ec)")
    }

    @Test func labelsEscapeTheirBrackets() {
        #expect(md(#"<a href="https://x.test">see [1] here</a>"#) == #"[see \[1\] here](https://x.test)"#)
        #expect(md(#"<img src="https://x.test/i.png" alt="a]b">"#) == #"![a\]b](https://x.test/i.png)"#)
    }

    @Test func linkEdgeWhitespaceStaysInTheSentence() {
        #expect(md(#"<p>a<a href="https://x.test"> b</a>c</p>"#) == "a [b](https://x.test)c")
        #expect(md(#"<p>see<a href="https://x.test">docs </a>now</p>"#) == "see[docs](https://x.test) now")
    }

    @Test func imagesAreReferencesNeverData() {
        #expect(md(#"<img src="https://x.y/i.png" alt="chart">"#) == "![chart](https://x.y/i.png)")
        #expect(md(#"<img src="data:image/png;base64,AAAA" alt="inline">"#) == "inline")
    }

    @Test func inlineCodeAndCodeBlocks() {
        #expect(md("<p>run <code>make test</code></p>") == "run `make test`")
        #expect(md("<p><code>a`b</code></p>") == "``a`b``")
        #expect(md("<pre><code class=\"language-swift\">let x = 1&lt;2\nprint(x)\n</code></pre>") == "```swift\nlet x = 1<2\nprint(x)\n```")
        #expect(md("<pre>has ``` inside</pre>") == "````\nhas ``` inside\n````")
    }

    @Test func codeKeepsItsWhitespace() {
        #expect(md("<pre>  indented\n\tand tabbed</pre>") == "```\n  indented\n\tand tabbed\n```")
    }

    @Test func lists() {
        #expect(md("<ul><li>one</li><li>two</li></ul>") == "- one\n- two")
        #expect(md(#"<ol start="3"><li>c</li><li>d</li></ol>"#) == "3. c\n4. d")
        #expect(md("<ul><li>parent<ul><li>child</li></ul></li><li>next</li></ul>") == "- parent\n  - child\n- next")
        #expect(md("<ul><li>unclosed<li>items</ul>") == "- unclosed\n- items")
    }

    @Test func checklists() {
        #expect(md(#"<ul><li><input type="checkbox" checked> done</li><li><input type="checkbox"> todo</li></ul>"#)
            == "- [x] done\n- [ ] todo")
    }

    @Test func blockquotes() {
        #expect(md("<blockquote><p>a</p><p>b</p></blockquote>") == "> a\n>\n> b")
    }

    @Test func tables() {
        let html = "<table><thead><tr><th>Name</th><th>Value</th></tr></thead><tbody><tr><td>a|b</td><td>1</td></tr><tr><td>c</td></tr></tbody></table>"
        #expect(md(html) == "| Name | Value |\n| --- | --- |\n| a\\|b | 1 |\n| c |  |")
    }

    @Test func lineBreaksAndRules() {
        #expect(md("<p>line one<br>line two</p><hr><p>after</p>") == "line one\\\nline two\n\n---\n\nafter")
    }

    @Test func entities() {
        #expect(md("<p>&lt;tag&gt; &amp; &quot;q&quot; &#8212; &#x2192; &nbsp;x &bogus;</p>") == "<tag> & \"q\" — → x &bogus;")
    }

    @Test func invisibleContentIsDropped() {
        #expect(md("<style>p{color:red}</style><script>if (a < b) {}</script><!-- c --><p>shown</p>") == "shown")
    }

    @Test func browserPasteboardWrapper() {
        let html = """
        <html><head><meta charset="utf-8"></head><body>
        <!--StartFragment--><h2>Release</h2><p>Ships <b>today</b>.</p><!--EndFragment-->
        </body></html>
        """
        #expect(md(html) == "## Release\n\nShips **today**.")
    }

    @Test func googleDocsWrapperAroundParagraphs() {
        let html = #"<b style="font-weight:normal;" id="docs-internal-guid-2"><p>First</p><p><span style="font-weight:700">Second</span></p></b>"#
        #expect(md(html) == "First\n\n**Second**")
    }

    @Test func googleDocsStyling() {
        let html = #"<b style="font-weight:normal;" id="docs-internal-guid-1"><span style="font-weight:700">Bold</span> <span style="font-style:italic">it</span> plain</b>"#
        #expect(md(html) == "**Bold** *it* plain")
    }

    @Test func textIsNotEscaped() {
        #expect(md("<p>snake_case and a*b and #hash</p>") == "snake_case and a*b and #hash")
    }

    @Test func hardBreaksStayOutsideEmphasis() {
        #expect(md("<p><b>bold<br></b>next</p>") == "**bold**\\\nnext")
        #expect(md("<p>a<b><br>bold</b></p>") == "a\\\n**bold**")
        #expect(md("<p><b><br></b>x</p>") == "\\\nx")
    }

    @Test func codeBlocksKeepConsecutiveBlankLines() {
        #expect(md("<pre>a\n\n\nb</pre>") == "```\na\n\n\nb\n```")
    }

    @Test func hugeOrderedListStartsDoNotOverflow() {
        #expect(md(#"<ol start="9223372036854775807"><li>a<li>b</ol>"#) == "1. a\n2. b")
        #expect(md(#"<ol start="999999998"><li>a<li>b</ol>"#) == "999999998. a\n999999999. b")
    }

    @Test func quotedGreaterThanStaysInTheAttribute() {
        #expect(md(#"<a href="https://e.test/?q=a>b">link</a>"#) == "[link](https://e.test/?q=a%3Eb)")
        #expect(md(#"<img alt='x > y' src="https://e.test/i.png">"#) == "![x > y](https://e.test/i.png)")
    }

    @Test func tableCellBlocksAreSeparated() {
        #expect(md("<table><tr><th>h</th></tr><tr><td><p>one</p><p>two</p></td></tr></table>") == "| h |\n| --- |\n| one two |")
    }

    @Test func pathologicalInputIsLinear() {
        for input in [String(repeating: "<", count: 100_000), String(repeating: "<a", count: 50_000)] {
            let elapsed = ContinuousClock().measure { _ = md(input) }
            #expect(elapsed < .seconds(1), "took \(elapsed)")
        }
    }

    @Test func deepNestingDoesNotOverflowTheStack() {
        let html = String(repeating: "<span>", count: 50_000) + "deep" + String(repeating: "</span>", count: 50_000)
        #expect(md(html) == "deep")
    }

    @Test func malformedInputDoesNotCrash() {
        for html in ["<", "<p", "</div>", "<a href=", "<<<>>>", "<p>unterminated", "&#99999999;", "<pre><code>", "<table><td>x"] {
            _ = md(html)
        }
        #expect(md("a < b and c > d") == "a < b and c > d")
    }
}
