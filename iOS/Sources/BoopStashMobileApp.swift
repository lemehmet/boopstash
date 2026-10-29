import BoopstashCore
import SwiftUI

/// BoopStash for iPhone and iPad (#65): the same notes, search and age
/// filter as the Mac, a reader with highlighting and light editing. The
/// privacy rules are the Mac's (ADR 0001): no network, the clipboard read
/// only when asked, AI on device only.
@main
struct BoopStashMobileApp: App {
    @State private var model: NotesModel?
    @State private var openError: String?
    @Environment(\.scenePhase) private var phase

    init() {
        do {
            _model = State(initialValue: try NotesModel.live())
        } catch {
            _openError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                NotesView(model: model)
                    .onChange(of: phase) { _, phase in
                        // Leaving the foreground may be the last chance to save;
                        // coming back may be on another day.
                        // The store is shared with the share extension: it lets go of
                        // its locks in the background, or iOS would end the app.
                        switch phase {
                        case .active:
                            NoteStore.resumeSharedStores()
                            // Notes shared while away were written by the extension.
                            model.refresh()
                        case .background:
                            model.drafts.flushAll()
                            NoteStore.suspendSharedStores()
                        default:
                            model.drafts.flushAll()
                        }
                    }
            } else {
                ContentUnavailableView("BoopStash could not open its notes", systemImage: "exclamationmark.triangle",
                                       description: Text(openError ?? ""))
            }
        }
    }
}
