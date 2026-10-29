import BoopstashCore
import SwiftUI

struct NotesView: View {
    @Bindable var model: NotesModel
    @State private var selection: UUID?

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
                NoteEditorView(model: model, note: note).id(id)
            } else {
                ContentUnavailableView("No note selected", systemImage: "note.text")
            }
        }
        .onChange(of: selection) { old, _ in
            if let old { model.drafts.flush(old) }
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

    var body: some View {
        VStack(spacing: 0) {
            TextField(note.titleIsUserSet ? "Title" : note.title, text: $title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onSubmit { model.drafts.rename(note.id, to: title) }
            Divider()
            PlainTextEditor(text: note.body, choice: note.syntaxChoice) { model.drafts.edit(note.id, body: $0) }
        }
        .onAppear { title = note.titleIsUserSet ? note.title : "" }
        .navigationBarTitleDisplayMode(.inline)
    }
}
