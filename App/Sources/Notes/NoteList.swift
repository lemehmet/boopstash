import BoopstashCore
import SwiftUI

struct NoteList: View {
    @Bindable var model: AppModel
    @State private var dropTargeted = false
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"

    /// `related`: found by meaning, so never "in image", which is about
    /// where the search's words matched.
    private func row(_ note: Note, related: Bool = false) -> some View {
        NoteRow(note: note, foundInImage: !related && !model.query.text.isEmpty && !model.query.matchesWithoutImages(note),
                labels: model.labels(of: note.id), onLabel: { model.addLabelFilter($0.id) })
            .tag(note.id)
            .contextMenu {
                Button("Show Similar Notes") { model.showSimilar(to: note.id) }
                Menu("Labels") {
                    ForEach(model.labelCatalog.labels) { label in
                        Toggle(label.name, isOn: Binding(get: { model.carries(label.id, note.id) },
                                                         set: { _ in model.toggleLabel(label.id, on: note.id) }))
                    }
                    if !model.labelCatalog.labels.isEmpty { Divider() }
                    Button("Edit Labels…") {
                        settingsTab = "labels"
                        openSettings()
                    }
                }
                Divider()
                Button("Delete", role: .destructive) { model.delete(note.id) }
            }
    }

    var body: some View {
        List(selection: $model.selection) {
            if let id = model.similarTo {
                // Similar notes in place of the list (#157).
                Section {
                    ForEach(model.related) { row($0, related: true) }
                } header: {
                    HStack {
                        Text("Similar to \(model.note(id: id)?.title ?? "this note")").lineLimit(1)
                        Spacer()
                        Button("Done") { model.similarTo = nil }.buttonStyle(.borderless)
                    }
                }
            } else {
                ForEach(model.notes) { row($0) }
                if !model.related.isEmpty {
                    // Close in meaning, though the words differ (#157).
                    Section("Similar in meaning") {
                        ForEach(model.related) { row($0, related: true) }
                    }
                }
            }
        }
        .overlay {
            if model.similarTo != nil, model.related.isEmpty {
                ContentUnavailableView("No similar notes", systemImage: "sparkle.magnifyingglass",
                                       description: Text("Notes close in meaning appear here once they have been read."))
            } else if model.similarTo == nil, model.notes.isEmpty, model.related.isEmpty {
                if model.query.text.isEmpty && model.query.days == nil && model.query.labels.isEmpty {
                    ContentUnavailableView("No notes yet", systemImage: "tray",
                                           description: Text("⌘N for a new note, ⌥⌘N to save what is on the clipboard, or drop text or a text file here."))
                } else if model.query.text.isEmpty {
                    // Only the Filter menu's choices filter.
                    ContentUnavailableView("No matching notes", systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text("No note matches the filter."))
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
                    if !model.labelCatalog.labels.isEmpty {
                        // A note must carry every checked label (#183).
                        Section("Labels") {
                            ForEach(model.labelCatalog.labels) { label in
                                Toggle(label.name, isOn: Binding(get: { model.isFiltering(by: label.id) },
                                                                 set: { _ in model.toggleLabelFilter(label.id) }))
                            }
                        }
                    }
                } label: {
                    Label("Filter", systemImage: model.query.scope == .everywhere && model.query.days == nil && model.query.labels.isEmpty
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
    }
}

struct NoteRow: View {
    let note: Note
    /// The filter matched only text recognised in the note's images.
    var foundInImage = false
    /// From the model's catalog, never a read per row.
    var labels: [NoteLabel] = []
    var onLabel: (NoteLabel) -> Void = { _ in }

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
                if foundInImage {
                    Text("·")
                    Label("in image", systemImage: "text.viewfinder").labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if !labels.isEmpty {
                LabelChips(labels: labels, onSelect: onLabel)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 2)
    }
}
