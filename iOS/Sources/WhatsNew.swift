import BoopstashCore
import SwiftUI
import UIKit

/// What's New on iOS (#253): a sheet once after an update, and every
/// version in Settings ▸ What's New. The notes are bundled; what to show is
/// decided by Core's `ReleaseNotesOffer`.
extension NotesModel {
    /// Save as Note: an ordinary note holding the notes as shown, titled
    /// with the newest version.
    @discardableResult
    func saveReleaseNotes(_ releases: [ReleaseNotes.Release], now: Date = Date()) -> Bool {
        let note = Note(title: ReleaseNotes.title(for: releases), titleIsUserSet: true,
                        body: ReleaseNotes.markdown(releases), createdAt: now)
        do {
            try store.save(note)
            return true
        } catch {
            banner = "Could not save: \(error.localizedDescription)"
            return false
        }
    }
}

/// The list with its two actions; the pasteboard is only ever written.
struct WhatsNewList: View {
    let model: NotesModel
    let releases: [ReleaseNotes.Release]

    var body: some View {
        ReleaseNotesView(releases: releases, copy: {
            UIPasteboard.general.string = $0
            return true
        }, save: { model.saveReleaseNotes(releases) })
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shown once after an update.
struct WhatsNewSheet: View {
    let model: NotesModel
    let releases: [ReleaseNotes.Release]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WhatsNewList(model: model, releases: releases)
                .toolbar { Button("Done") { dismiss() } }
        }
    }
}
