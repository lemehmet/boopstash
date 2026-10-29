import AppKit
import BoopstashCore
import SwiftUI
import Testing
@testable import Boopstash

/// The native preview, drawn in a window: attachment images come from the
/// store; there is nothing that could load a remote one.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PreviewTests {
    @Test func attachmentsAreAskedForAndRemoteImagesAreNot() async throws {
        let id = UUID()
        var asked: [UUID] = []
        let markdown = "# Title\n\n![plot](attachment:\(id.uuidString.lowercased()))\n\n![remote](https://example.com/x.png)\n\n```json\n{\"a\": 1}\n```"
        let view = PreviewView(markdown: markdown, appearance: EditorAppearance()) { requested in
            asked.append(requested)
            return NSImage(size: NSSize(width: 4, height: 4))
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<150 where asked.isEmpty {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Set(asked) == [id])
        window.close()
    }

    @Test func thePaletteFollowsTheTheme() throws {
        let nord = try #require(Theme.named("nord"))
        let palette = PreviewPalette(theme: nord)
        #expect(NSColor(palette.color(for: .keyword)).usingColorSpace(.sRGB)?.redComponent == NSColor(nord.color(for: .keyword)).usingColorSpace(.sRGB)?.redComponent)
        #expect(PreviewPalette(theme: nil).theme == nil)
    }
}
