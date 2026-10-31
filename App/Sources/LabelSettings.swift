import BoopstashCore
import SwiftUI

/// Settings ▸ Labels (#183): every label as a chip with its description and
/// how many notes carry it; New Label, editing and deleting.
struct LabelSettings: View {
    let model: AppModel?
    /// The label being edited; a new one has no ID yet.
    @State private var editing: LabelDraft?
    @State private var deleting: NoteLabel?

    var body: some View {
        Form {
            if let model {
                Section {
                    if model.labelCatalog.labels.isEmpty {
                        Text("No labels yet. Labels put on notes appear here; Note ▸ Labels… (⌃⌘L) makes them too.")
                            .foregroundStyle(.secondary)
                    }
                    let counts = model.labelCatalog.useCounts
                    ForEach(model.labelCatalog.labels) { label in
                        row(label, uses: counts[label.id] ?? 0)
                    }
                } header: {
                    HStack {
                        Text("Labels")
                        Spacer()
                        Button("New Label") { editing = LabelDraft(color: LabelColor.random()) }
                    }
                }
            } else {
                Text("Labels are not available: BoopStash could not open its notes.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { draft in
            if let model { LabelEditor(model: model, draft: draft) }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { label in
            Button("Delete", role: .destructive) { model?.deleteLabel(label.id) }
        } message: { label in
            Text(deleteMessage(label))
        }
    }

    private func row(_ label: NoteLabel, uses: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The chip and its text read as one element; Edit and Delete stay
            // separate controls for VoiceOver.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                LabelChip(label, font: .callout.weight(.medium))
                VStack(alignment: .leading, spacing: 2) {
                    if !label.details.isEmpty {
                        Text(label.details).lineLimit(2)
                    }
                    Text(uses == 1 ? "1 note" : "\(uses) notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button("Edit") { editing = LabelDraft(label) }
                .accessibilityLabel("Edit \(label.name)")
            Button("Delete…", role: .destructive) { deleting = label }
                .accessibilityLabel("Delete \(label.name)")
        }
    }

    private var deleteTitle: String {
        deleting.map { "Delete the label “\($0.name)”?" } ?? ""
    }

    private func deleteMessage(_ label: NoteLabel) -> String {
        let uses = model?.labelCatalog.useCounts[label.id] ?? 0
        return switch uses {
        case 0: "No note carries it."
        case 1: "It will be taken off the 1 note that carries it. The note itself stays."
        default: "It will be taken off the \(uses) notes that carry it. The notes themselves stay."
        }
    }
}

/// What the editor works on: a copy, saved only on Save.
struct LabelDraft: Identifiable {
    /// The label's ID, nil for a new one.
    let labelID: UUID?
    var name: String
    var color: String
    var details: String
    let id = UUID()

    init(color: String) {
        labelID = nil
        name = ""
        self.color = color
        details = ""
    }

    init(_ label: NoteLabel) {
        labelID = label.id
        name = label.name
        color = label.color
        details = label.details
    }
}

/// Editing one label: name, description and colour, with the chip as it
/// will look. Colours come from the presets first; a `#rrggbb` field and a
/// shuffle button do the rest.
struct LabelEditor: View {
    let model: AppModel
    @State var draft: LabelDraft
    @State private var colorText = ""
    @State private var saveProblem: String?
    @Environment(\.dismiss) private var dismiss

    private var nameProblem: String? {
        LabelName.problem(draft.name, among: model.labelCatalog.labels, renaming: draft.labelID).map(LabelName.message)
    }

    private var parsedColor: String? { LabelColor.parse(colorText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.labelID == nil ? "New Label" : "Edit Label").font(.headline)
            HStack {
                Spacer()
                LabelChip(name: preview, color: parsedColor ?? draft.color, font: .body.weight(.medium))
                    .accessibilityLabel("Preview: \(preview)")
                Spacer()
            }
            .padding(.vertical, 8)
            Form {
                TextField("Name", text: $draft.name)
                TextField("Description", text: $draft.details, prompt: Text("Optional"))
                LabeledContent("Colour") {
                    VStack(alignment: .leading, spacing: 8) {
                        swatches
                        HStack {
                            TextField("Colour", text: $colorText, prompt: Text("#rrggbb"))
                                .labelsHidden()
                                .frame(width: 90)
                                .font(.body.monospaced())
                            Button { setColor(LabelColor.random(otherThan: draft.color)) } label: {
                                Image(systemName: "shuffle")
                            }
                            .help("Another preset colour")
                            .accessibilityLabel("Shuffle colour")
                        }
                    }
                }
            }
            .formStyle(.columns)
            if let problem = nameProblem ?? (parsedColor == nil ? LabelName.message(.invalidColor(colorText)) : nil) ?? saveProblem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.labelID == nil ? "Create Label" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameProblem != nil || parsedColor == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { colorText = draft.color }
        .onChange(of: colorText) { _, text in
            if let parsed = LabelColor.parse(text) { draft.color = parsed }
        }
        .onChange(of: draft.name) { saveProblem = nil }
    }

    private var preview: String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Label preview" : trimmed
    }

    private var swatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
            ForEach(LabelColor.palette, id: \.self) { color in
                Button { setColor(color) } label: {
                    Circle()
                        .fill(Color(labelHex: color))
                        .frame(width: 20, height: 20)
                        .overlay {
                            if color == draft.color {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color(labelHex: LabelColor.textColor(on: color)))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(color)
                .accessibilityLabel(color)
                .accessibilityAddTraits(color == draft.color ? .isSelected : [])
            }
        }
    }

    private func setColor(_ color: String) {
        draft.color = color
        colorText = color
    }

    private func save() {
        if let problem = model.saveLabel(id: draft.labelID, name: draft.name, color: draft.color, details: draft.details) {
            saveProblem = problem
        } else {
            dismiss()
        }
    }
}
