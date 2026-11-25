import AppKit
import BoopstashCore
import SwiftUI

/// What's New on the Mac (#253): a sheet on the main window, once, on the
/// first launch of a newer version; and a window listing every version,
/// from Help ▸ What's New and Settings. The notes are bundled; what to show
/// is decided by Core's `ReleaseNotesOffer`.
@MainActor
enum WhatsNew {
    static let windowID = "whats-new"

    /// The main window the sheet would hang on.
    static var mainWindow: NSWindow? {
        NSApp.windows.first { MainWindowRegistry.contains($0) && $0.isVisible }
    }

    /// Never over another sheet or an alert, and only on a window in view:
    /// otherwise the notes wait for the next launch.
    static func canPresent(over window: NSWindow?, modal: NSWindow? = NSApp.modalWindow) -> Bool {
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return window.attachedSheet == nil && modal == nil
    }

    /// The notes as Markdown, as plain text. Only ever writes.
    @discardableResult
    static func copy(_ markdown: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(markdown, forType: .string)
    }
}

extension AppModel {
    /// Save as Note: an ordinary note holding the notes as shown, titled
    /// with the newest version, which the model never renames.
    @discardableResult
    func saveReleaseNotes(_ releases: [ReleaseNotes.Release], now: Date = Date()) -> Note? {
        let note = Note(title: ReleaseNotes.title(for: releases), titleIsUserSet: true,
                        body: ReleaseNotes.markdown(releases), createdAt: now)
        return insert(note) ? note : nil
    }
}

/// The releases a sheet shows.
struct WhatsNewItem: Identifiable {
    let id = UUID()
    let releases: [ReleaseNotes.Release]
}

/// Shown once after an update, on the main window.
struct WhatsNewSheet: View {
    let model: AppModel
    let releases: [ReleaseNotes.Release]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("What's New in BoopStash")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
            ReleaseNotesView(releases: releases, copy: { WhatsNew.copy($0) }, save: {
                // The note is selected behind the sheet: out of the way.
                guard model.saveReleaseNotes(releases) != nil else { return false }
                dismiss()
                return true
            })
            .overlay(alignment: .bottomTrailing) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .padding(12)
            }
        }
        .frame(width: 520, height: 440)
    }
}

/// Help ▸ What's New: every version, newest first.
struct WhatsNewWindow: View {
    let model: AppModel?

    var body: some View {
        ReleaseNotesView(releases: LiveReleaseNotes.all, copy: { WhatsNew.copy($0) },
                         save: model.map { model in { model.saveReleaseNotes(LiveReleaseNotes.all) != nil } })
            .frame(minWidth: 460, idealWidth: 520, minHeight: 320, idealHeight: 520)
    }
}

/// Help ▸ What's New, above Report a Problem.
struct WhatsNewCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Divider()
            Button("What's New") { openWindow(id: WhatsNew.windowID) }
        }
    }
}
