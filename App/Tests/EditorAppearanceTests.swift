import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

@MainActor
@Suite(.serialized)
struct EditorAppearanceTests {
    func host(_ text: String = "") -> (NSWindow, BoopTextView) {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        view.load(text)
        return (window, view)
    }

    func same(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    @Test func aThemeColoursTheEditor() throws {
        let (window, view) = host("let a = 1")
        let nord = try #require(Theme.named("nord"))
        view.editorAppearance = EditorAppearance(lightThemeID: "nord", darkThemeID: "nord")
        #expect(view.drawsBackground)
        #expect(same(view.backgroundColor, NSColor(nord.background)))
        #expect(same(view.insertionPointColor, NSColor(nord.caret)))
        #expect(same(view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor(nord.foreground)))
        #expect(view.syntax.theme?.id == "nord")
        window.close()
    }

    @Test func highlightsUseTheThemesColours() async throws {
        let (window, view) = host()
        let dracula = try #require(Theme.named("dracula"))
        view.editorAppearance = EditorAppearance(lightThemeID: "dracula", darkThemeID: "dracula")
        let text = #"{"name": "boop"}"#
        view.load(text, syntax: .language(.json))
        let at = (text as NSString).range(of: "\"boop\"").location + 1
        var painted: NSColor?
        for _ in 0..<100 where painted == nil {
            try await Task.sleep(for: .milliseconds(20))
            painted = BoopTextViewTests.renderingColor(in: view, at: at)
        }
        #expect(same(painted, NSColor(dracula.color(for: .string))), "got \(String(describing: painted))")
        window.close()
    }

    @Test func fontFamilyAndSizeApply() {
        let (window, view) = host("text")
        view.editorAppearance = EditorAppearance(fontFamily: "Menlo", fontSize: 20)
        let font = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 20)
        #expect(font?.familyName == "Menlo")
        view.editorAppearance = EditorAppearance(fontFamily: "No Such Font", fontSize: 11)
        let fallback = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(fallback?.pointSize == 11)
        #expect(fallback?.isFixedPitch == true, "an unknown family falls back to the system monospaced font")
        window.close()
    }

    @Test func lightAndDarkFollowTheSystemAppearance() throws {
        let (window, view) = host("x")
        view.editorAppearance = EditorAppearance(lightThemeID: "github-light", darkThemeID: "github-dark")
        view.appearance = NSAppearance(named: .darkAqua)
        #expect(view.activeTheme?.id == "github-dark")
        #expect(same(view.backgroundColor, NSColor(try #require(Theme.named("github-dark")).background)))
        view.appearance = NSAppearance(named: .aqua)
        #expect(view.activeTheme?.id == "github-light")
        #expect(same(view.backgroundColor, NSColor(try #require(Theme.named("github-light")).background)))
        window.close()
    }

    @Test func systemThemeUsesSystemColours() {
        let (window, view) = host("x")
        view.editorAppearance = EditorAppearance(lightThemeID: "nord", darkThemeID: "nord")
        view.editorAppearance = EditorAppearance()
        #expect(view.activeTheme == nil)
        #expect(!view.drawsBackground)
        #expect(view.syntax.theme == nil)
        window.close()
    }
}
