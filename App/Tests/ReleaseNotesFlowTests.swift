import AppKit
import BoopstashCore
import SwiftUI
import Testing
@testable import Boopstash

/// What's New (#253) in the app: the bundled notes, the sheet's gate, Copy
/// and Save as Note, against an in-memory store, defaults of their own and
/// a private pasteboard.
@MainActor
@Suite(.serialized)
struct ReleaseNotesFlowTests {
    let model: AppModel
    let defaults: UserDefaults
    let notes = ReleaseNotes(json: Data("""
        { "releases": [
            { "version": "2.1.0", "date": "2026-02-01", "notes": [ { "on": "mac", "text": "A Mac line." }, { "on": "ios", "text": "An iOS line." } ] },
            { "version": "2.0.0", "date": "2026-01-01", "notes": [ { "text": "A line for both." } ] }
        ] }
        """.utf8))

    init() throws {
        model = AppModel(store: try .inMemory())
        let name = "ReleaseNotesFlowTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
    }

    private func offer(running: String) -> ReleaseNotesOffer {
        ReleaseNotesOffer(notes: notes, running: running, ledger: ReleaseNotesLedger(defaults: defaults),
                          existingInstall: true, platform: .mac)
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: The bundled notes

    @Test func theBundledNotesParseCompletely() {
        let bundled = LiveReleaseNotes.notes
        #expect(bundled.problems.isEmpty)
        // Every release so far, newest first.
        let versions = bundled.releases.map(\.version.description)
        #expect(versions.suffix(11) == ["0.4.6", "0.4.5", "0.4.4", "0.4.3", "0.4.2", "0.4.1", "0.4.0", "0.3.0", "0.2.0", "0.1.1", "0.1.0"])
        #expect(!LiveReleaseNotes.all.isEmpty)
    }

    @Test func theBundledLinesAreProseWithoutIssueNumbers() {
        let bundled = LiveReleaseNotes.notes
        for line in bundled.releases.flatMap(\.lines) + bundled.unreleased {
            #expect(line.text.firstMatch(of: /#\d/) == nil, "\(line.text)")
            #expect(!line.text.contains("**") && !line.text.contains("`"), "\(line.text)")
        }
    }

    // MARK: Shown once

    @Test func aModelNotMadeByARealLaunchOffersNothing() {
        // Tests and demo mode make their models directly: no offer, no sheet.
        #expect(model.whatsNew == nil)
    }

    @Test func theNotesAreOfferedOnceAndNotAfterTheyAreDismissed() {
        defaults.set("2.0.0", forKey: ReleaseNotesLedger.key)
        model.whatsNew = offer(running: "2.1.0")
        let shown = model.whatsNew?.take(canPresent: true) ?? []
        #expect(shown.map(\.version.description) == ["2.1.0"])
        #expect(shown.first?.lines.map(\.text) == ["A Mac line."])
        #expect(model.whatsNew?.take(canPresent: true).isEmpty == true)
        model.whatsNew?.dismissed()
        // The next launch.
        model.whatsNew = offer(running: "2.1.0")
        #expect(model.whatsNew?.take(canPresent: true).isEmpty == true)
    }

    // MARK: Not in the way

    @Test func theSheetNeedsAMainWindowInView() {
        #expect(!WhatsNew.canPresent(over: nil, modal: nil))
        let closed = window()
        #expect(!WhatsNew.canPresent(over: closed, modal: nil))
        let open = window()
        open.orderFront(nil)
        defer { open.close() }
        #expect(WhatsNew.canPresent(over: open, modal: nil))
        // An alert run modally is in the way too.
        #expect(!WhatsNew.canPresent(over: open, modal: window()))
    }

    @Test func aViewLearnsTheWindowItIsIn() {
        // With several main windows, each asks about its own.
        let host = HostWindowReader.Host()
        let hosting = NSHostingView(rootView: Color.clear.background(HostWindowReader(host: host)))
        #expect(host.window == nil)
        let open = window()
        open.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        #expect(host.window === open)
        open.contentView = nil
        #expect(host.window == nil)
    }

    @Test func theSheetNeverGoesOverAnotherSheet() async throws {
        let main = window()
        main.orderFront(nil)
        defer { main.close() }
        let other = window()
        main.beginSheet(other, completionHandler: nil)
        #expect(try await eventually { main.attachedSheet != nil })
        #expect(!WhatsNew.canPresent(over: main, modal: nil))
        // Blocked, the notes wait for the next launch: nothing is recorded.
        defaults.set("2.0.0", forKey: ReleaseNotesLedger.key)
        model.whatsNew = offer(running: "2.1.0")
        #expect(model.whatsNew?.take(canPresent: WhatsNew.canPresent(over: main, modal: nil)).isEmpty == true)
        #expect(ReleaseNotesLedger(defaults: defaults).lastSeen == ReleaseVersion("2.0.0"))
        main.endSheet(other)
        #expect(try await eventually { main.attachedSheet == nil })
        #expect(WhatsNew.canPresent(over: main, modal: nil))
    }

    // MARK: Copy and Save as Note

    @Test func copyPutsTheShownNotesOnThePasteboardAsMarkdown() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let shown = notes.releases(for: .mac)
        #expect(WhatsNew.copy(ReleaseNotes.markdown(shown), to: pasteboard))
        let copied = try #require(pasteboard.string(forType: .string))
        #expect(copied == "# What's New in BoopStash\n\n## 2.1.0 (2026-02-01)\n\n- A Mac line.\n\n## 2.0.0 (2026-01-01)\n\n- A line for both.\n")
    }

    @Test func saveAsNoteKeepsTheSameMarkdownTitledWithTheVersion() throws {
        let shown = notes.releases(for: .mac)
        let made = try #require(model.saveReleaseNotes(shown))
        let saved = try #require(try model.store.note(id: made.id))
        #expect(saved.body == ReleaseNotes.markdown(shown))
        #expect(saved.title == "What's New in BoopStash 2.1.0")
        #expect(saved.titleIsUserSet)
        #expect(model.selection == made.id)
    }

    @Test func aNoteThatCannotBeSavedIsReported() {
        struct Refused: Error {}
        model.writeNote = { _ in throw Refused() }
        #expect(model.saveReleaseNotes(notes.releases(for: .mac)) == nil)
        #expect(model.banner != nil)
    }

    // MARK: The menu

    @Test func theHelpMenuHasWhatsNew() async throws {
        func titles(_ menu: NSMenu?) -> [String] {
            (menu?.items ?? []).flatMap { [$0.title] + titles($0.submenu) }
        }
        let help = try #require(NSApp.mainMenu?.items.first { $0.title == "Help" })
        #expect(try await eventually { titles(help.submenu).contains("What's New") })
    }
}
