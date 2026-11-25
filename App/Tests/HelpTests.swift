import AppKit
import BoopstashCore
import SwiftUI
import Testing
@testable import Boopstash

/// Help ▸ BoopStash Help (#254): the README the build bundled, and the one
/// window that shows it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HelpTests {
    private func helpWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.title == HelpWindow.title && $0.isVisible }
    }

    @Test func theBundledREADMEIsThereAndRendersWithNothingToLoad() async throws {
        let markdown = try #require(LiveHelp.markdown)
        let blocks = await MarkdownPreview.blocks(for: markdown, linkBase: HelpPage.linkBase)
        #expect(!blocks.isEmpty)
        // The preview has no block that loads anything: a picture in the
        // README can only be named, since the README has no attachments.
        func images(_ blocks: [PreviewBlock]) -> [PreviewImage] {
            blocks.flatMap { block -> [PreviewImage] in
                switch block {
                case .image(let image): [image]
                case .quote(let inner): images(inner)
                case .list(_, _, let items): items.flatMap { images($0.blocks) }
                default: []
                }
            }
        }
        for image in images(blocks) {
            guard case .blocked = image else {
                Issue.record("\(image)")
                continue
            }
        }
    }

    /// That the page has nothing to load is checked on its blocks, above
    /// and in Core: the view asks for a picture only for an attachment.
    @Test func thePageIsDrawn() async throws {
        let view = PreviewView(markdown: try #require(LiveHelp.markdown), appearance: EditorAppearance(), linkBase: HelpPage.linkBase)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        // Drawn once its blocks arrive: the page is taller than the window.
        #expect(try await eventually {
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height > 500
        })
    }

    @Test func theMenuItemOpensOneWindowAndBringsItForwardWhenChosenAgain() async throws {
        let help = try #require(NSApp.mainMenu?.items.first { $0.title == "Help" }?.submenu)
        #expect(try await eventually { help.items.contains { $0.title == HelpWindow.title } })
        // One item, and the app's: the system's would look for a help book
        // and put up an alert saying there is none.
        let items = help.items.filter { $0.title == HelpWindow.title }
        #expect(items.count == 1)
        let item = try #require(items.first)
        try #require(item.action != #selector(NSApplication.showHelp(_:)))
        defer { helpWindows().forEach { $0.close() } }

        help.performActionForItem(at: help.index(of: item))
        #expect(try await eventually { helpWindows().count == 1 })
        let window = try #require(helpWindows().first)

        // Behind another window, then chosen again: the same window, in front.
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFront(nil)
        defer { other.close() }
        #expect(try await eventually { NSApp.orderedWindows.first === other })
        help.performActionForItem(at: help.index(of: item))
        #expect(try await eventually { NSApp.orderedWindows.first === window })
        #expect(helpWindows().count == 1)
    }
}
