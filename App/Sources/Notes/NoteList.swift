import BoopstashCore
import SwiftUI

struct NoteList: View {
    @Bindable var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        List(model.notes, selection: $model.selection) { note in
            NoteRow(note: note)
                .tag(note.id)
                .contextMenu {
                    Button("Delete", role: .destructive) { model.delete(note.id) }
                }
        }
        .overlay {
            if model.notes.isEmpty {
                if model.query.text.isEmpty && model.query.days == nil {
                    ContentUnavailableView("No notes yet", systemImage: "tray",
                                           description: Text("⌘N for a new note, ⌥⌘N to save what is on the clipboard, or drop text or a text file here."))
                } else {
                    ContentUnavailableView.search(text: model.query.text)
                }
            }
        }
        .onDrop(of: DropCapture.acceptedTypes, isTargeted: $dropTargeted) { providers in
            DropCapture.handle(providers, model: model)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .searchable(text: $model.query.text, placement: .sidebar, prompt: "Filter")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Look in", selection: $model.query.scope) {
                        Text("Title and content").tag(NoteQuery.Scope.everywhere)
                        Text("Title").tag(NoteQuery.Scope.title)
                        Text("Content").tag(NoteQuery.Scope.content)
                    }
                    Picker("Edited", selection: $model.query.days) {
                        Text("Any time").tag(Int?.none)
                        Text("Today").tag(Int?.some(1))
                        Text("Last 7 days").tag(Int?.some(7))
                        Text("Last 30 days").tag(Int?.some(30))
                    }
                } label: {
                    Label("Filter", systemImage: model.query.scope == .everywhere && model.query.days == nil
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .lineLimit(1)
                .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
            HStack(spacing: 4) {
                Text(note.updatedAt, format: .relative(presentation: .named))
                if let app = note.sourceAppName {
                    Text("·")
                    Text(app)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
