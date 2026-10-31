import AppKit
import BoopstashCore
import Testing
@testable import Boopstash

/// The folding gutter in a real editor (#189): a chevron sized from the
/// editor font, a gutter as wide as it needs, and the text beside it.
@MainActor
@Suite(.serialized)
struct FoldGutterTests {
    static let text = "# One\nbody\nmore\n# Two\nbody\n"

    func host(fontSize: Double) async throws -> (NSWindow, NSScrollView, BoopTextView, FoldGutter) {
        let (scroll, view) = BoopTextView.makeScrollable()
        scroll.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        view.editorAppearance = EditorAppearance(fontSize: fontSize)
        view.load(Self.text, syntax: .plain)
        // Let the plain-text parse report its (empty) blocks first.
        try await Task.sleep(for: .milliseconds(300))
        view.folding.setRegions([FoldRegion(startLine: 0, hidden: 1...2), FoldRegion(startLine: 3, hidden: 4...4)])
        scroll.layoutSubtreeIfNeeded()
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        return (window, scroll, view, try #require(view.foldGutter))
    }

    /// Ink (non-background) pixels the gutter draws, and the rows and
    /// columns they span.
    func ink(_ gutter: FoldGutter) -> (count: Int, rows: ClosedRange<Int>?, columns: ClosedRange<Int>?) {
        let rep = try! #require(gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds))
        gutter.cacheDisplay(in: gutter.bounds, to: rep)
        let background = rep.colorAt(x: 0, y: 0)
        var count = 0, minY = Int.max, maxY = Int.min, minX = Int.max, maxX = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y) != background {
                count += 1; minY = min(minY, y); maxY = max(maxY, y); minX = min(minX, x); maxX = max(maxX, x)
            }
        }
        return (count, count > 0 ? minY...maxY : nil, count > 0 ? minX...maxX : nil)
    }

    @Test(arguments: [9.0, 13.0, 24.0, 36.0])
    func theGutterFollowsTheFontAndLeavesTheTextVisible(size: Double) async throws {
        let (window, scroll, view, gutter) = try await host(fontSize: size)
        let font = try #require(view.font)
        let metrics = FoldGutterMetrics(capHeight: font.capHeight)
        #expect(gutter.ruleThickness == metrics.width)
        // #180: the text starts after the gutter, and the gutter paints only itself.
        let textStart = scroll.convert(NSPoint(x: view.textContainerOrigin.x, y: 0), from: view).x
        let gutterEnd = scroll.convert(NSPoint(x: gutter.bounds.maxX, y: 0), from: gutter).x
        #expect(textStart >= gutterEnd, "the first column of text is not under the gutter")
        #expect(gutter.clipsToBounds)
        #expect(ink(gutter).count > 0, "a chevron is drawn")
        window.close()
    }

    /// One block, so the ink is one chevron: open (down), then folded
    /// (right), each about the size of the text's capitals: the right one
    /// as tall, the open one as wide.
    @Test(arguments: [13.0, 24.0])
    func theChevronIsAboutTheCapHeight(size: Double) async throws {
        let (window, _, view, gutter) = try await host(fontSize: size)
        view.folding.setRegions([FoldRegion(startLine: 0, hidden: 1...2)])
        let scale = CGFloat(try #require(gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds)).pixelsHigh) / gutter.bounds.height
        let capHeight = try #require(view.font).capHeight
        for folded in [false, true] {
            if folded { view.folding.foldAll() }
            let drawn = ink(gutter)
            let rows = try #require(drawn.rows), columns = try #require(drawn.columns)
            let extent = CGFloat(folded ? rows.count : columns.count) / scale
            #expect(extent >= capHeight * 0.6, "an arrow about the capitals' size, not a dot")
            #expect(extent <= capHeight * 1.3, "no larger than the capitals")
            #expect(columns.upperBound < Int(gutter.bounds.width * scale) - 1, "not clipped by the gutter's edge")
        }
        window.close()
    }

    /// The darkest/lightest ink: the chevron is the secondary label colour
    /// of the appearance it is drawn in, so it reads in light and dark.
    func inkBrightness(_ gutter: FoldGutter) -> CGFloat? {
        let rep = gutter.bitmapImageRepForCachingDisplay(in: gutter.bounds)!
        gutter.cacheDisplay(in: gutter.bounds, to: rep)
        let background = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0
        var best: CGFloat?
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let b = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent else { continue }
                if best.map({ abs(b - background) > abs($0 - background) }) ?? true { best = b }
            }
        }
        return best.map { $0 - background }
    }

    @Test func theChevronContrastsInLightAndDark() async throws {
        let (window, _, _, gutter) = try await host(fontSize: 13)
        window.appearance = NSAppearance(named: .aqua)
        let light = try #require(inkBrightness(gutter))
        window.appearance = NSAppearance(named: .darkAqua)
        let dark = try #require(inkBrightness(gutter))
        #expect(light < -0.2, "dark ink on a light editor")
        #expect(dark > 0.2, "light ink on a dark editor")
        window.close()
    }

    @Test func theSizeSettingResizesTheGutterAtOnce() async throws {
        let (window, _, view, gutter) = try await host(fontSize: 13)
        let small = gutter.ruleThickness
        view.editorAppearance = EditorAppearance(fontSize: 30)
        #expect(gutter.ruleThickness > small)
        #expect(gutter.ruleThickness == FoldGutterMetrics(capHeight: try #require(view.font).capHeight).width)
        window.close()
    }

    @Test func aClickBesideABlockStartTogglesIt() async throws {
        let (window, _, view, gutter) = try await host(fontSize: 24)
        let lineHeight = try #require(view.textLayoutManager?.textLayoutFragment(for: view.textLayoutManager!.documentRange.location))
            .layoutFragmentFrame.height
        let firstLineY = view.textContainerOrigin.y + lineHeight / 2
        func click(atY y: CGFloat, x: CGFloat) {
            let point = gutter.convert(NSPoint(x: x, y: gutter.convert(NSPoint(x: 0, y: y), from: view).y), to: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            gutter.mouseDown(with: event)
        }
        // Near the gutter's edge, not on the chevron itself.
        click(atY: firstLineY, x: 1)
        #expect(view.folding.folded == [0])
        click(atY: firstLineY, x: gutter.ruleThickness - 1)
        #expect(view.folding.folded.isEmpty)
        // Line 2 ("more") starts no block.
        click(atY: firstLineY + 2 * lineHeight, x: gutter.ruleThickness / 2)
        #expect(view.folding.folded.isEmpty)
        window.close()
    }
}
