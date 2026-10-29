import BoopstashCore
import SwiftUI

struct NotesView: View {
    @Bindable var model: NotesModel
    @State private var selection: UUID?
    @State private var settingsShown = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.notes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title.isEmpty ? "Untitled" : note.title).lineLimit(1)
                        Text(note.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(note.id)
                }
                .onDelete { offsets in
                    for index in offsets { model.delete(model.notes[index].id) }
                }
            }
            .navigationTitle("BoopStash")
            .searchable(text: $model.query.text, prompt: "Filter")
            .searchScopes($model.query.scope) {
                Text("Everywhere").tag(NoteQuery.Scope.everywhere)
                Text("Title").tag(NoteQuery.Scope.title)
                Text("Content").tag(NoteQuery.Scope.content)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Edited", selection: $model.query.days) {
                            Text("Any time").tag(Int?.none)
                            Text("Today").tag(Int?.some(1))
                            Text("Last 7 days").tag(Int?.some(7))
                            Text("Last 30 days").tag(Int?.some(30))
                        }
                    } label: {
                        Label("Edited", systemImage: "calendar")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { settingsShown = true }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("From Clipboard", systemImage: "doc.on.clipboard") {
                        if let note = model.newNoteFromClipboard() { selection = note.id }
                    }
                    Button("New Note", systemImage: "square.and.pencil") {
                        if let note = model.newNote() { selection = note.id }
                    }
                }
            }
        } detail: {
            if let id = selection, let note = model.drafts.note(id: id) {
                // A change from iCloud makes a new editor with the merged
                // note, title included.
                NoteEditorView(model: model, note: note).id("\(id)-\(model.remoteRevisions[id] ?? 0)")
            } else {
                ContentUnavailableView("No note selected", systemImage: "note.text")
            }
        }
        .onChange(of: selection) { old, _ in
            if let old { model.drafts.flush(old) }
        }
        .sheet(isPresented: $settingsShown) { SettingsView(model: model) }
        .onAppear {
            if selection == nil { selection = model.initialSelection }
            #if DEBUG
            // A shot of Settings (screenshots' demo mode).
            if model.demoSync, UserDefaults.standard.bool(forKey: "BoopStashDemoSettings") { settingsShown = true }
            #endif
        }
        .safeAreaInset(edge: .bottom) {
            if let banner = model.banner {
                HStack {
                    Text(banner).font(.callout)
                    Spacer()
                    Button("Dismiss") { model.banner = nil }
                }
                .padding(10)
                .background(.bar)
            }
        }
    }
}

struct NoteEditorView: View {
    let model: NotesModel
    let note: Note
    @State private var title = ""
    /// The rendered note in place of the editor (#65), as on the Mac.
    @AppStorage("previewShown") private var previewShown = false

    var body: some View {
        VStack(spacing: 0) {
            TextField(note.titleIsUserSet ? "Title" : note.title, text: $title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                // Saved as it changes, like the body, so leaving the field
                // any way at all keeps it.
                .onChange(of: title) { _, title in
                    // Only a real change: filling the field on appear is not a rename.
                    let current = model.drafts.note(id: note.id) ?? note
                    let changed = title.isEmpty ? current.titleIsUserSet : title != current.title || !current.titleIsUserSet
                    if changed { model.drafts.rename(note.id, to: title) }
                }
            Divider()
            if previewShown {
                // The draft, which may be newer than what was saved.
                PreviewView(markdown: model.drafts.note(id: note.id)?.body ?? note.body, appearance: EditorAppearance()) { [store = model.store] id in
                    guard let attachment = try? store.attachment(id: id) else { return nil }
                    return UIImage(contentsOfFile: store.fileURL(for: attachment).path)
                }
            } else {
                PlainTextEditor(text: model.drafts.note(id: note.id)?.body ?? note.body, choice: note.syntaxChoice, showMessage: { model.banner = $0 }) {
                    model.drafts.edit(note.id, body: $0)
                }
            }
        }
        .toolbar {
            Button(previewShown ? "Edit" : "Preview", systemImage: previewShown ? "pencil" : "eye") {
                model.drafts.flush(note.id)
                previewShown.toggle()
            }
        }
        .onAppear { title = note.titleIsUserSet ? note.title : "" }
        .onDisappear { model.drafts.flush(note.id) }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// iCloud sync, off by default: nothing contacts iCloud, not even to check
/// the account, until it is turned on (ADR 0008).
struct SettingsView: View {
    let model: NotesModel
    @AppStorage(NotesModel.syncKey) private var enabled = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Sync with iCloud", isOn: Binding(get: { (enabled || model.demoSync) && model.canSync }, set: { if !model.demoSync { model.setSyncEnabled($0) } }))
                        .disabled(!model.canSync)
                    if !model.canSync {
                        Text("This build of BoopStash was not signed for iCloud, so it cannot sync.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if enabled, let problem = model.syncAccountProblem ?? model.syncProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    if model.canSync, model.showsSyncing {
                        LabeledContent("Last synced", value: model.lastSynced.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet")
                        Button("Sync Now") { model.syncNow() }
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Notes and images go to your own iCloud, in fields encrypted on this device. With Advanced Data Protection they are end-to-end encrypted; without it, Apple holds the keys, as for most iCloud data.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
