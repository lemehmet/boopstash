import BoopstashCore
import SwiftUI

/// A note's labels (Note ▸ Labels…, ⌃⌘L): type to filter, ↑ and ↓ to
/// choose, Return or a click to put a label on or take it off, and
/// "Create label" for a name no label has.
struct LabelsPopover: View {
    @Bindable var model: AppModel
    let noteID: UUID
    @State private var text = ""
    @State private var highlighted: Int?
    @FocusState private var fieldFocused: Bool

    private var picker: LabelPicker { LabelPicker(labels: model.labelCatalog.labels, typed: text) }

    var body: some View {
        let picker = self.picker
        VStack(alignment: .leading, spacing: 0) {
            TextField("Filter or create labels", text: $text)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .focused($fieldFocused)
                .onSubmit { activate(picker.target(highlighted: highlighted)) }
                .onKeyPress(.downArrow) { highlighted = picker.move(highlighted, by: 1); return .handled }
                .onKeyPress(.upArrow) { highlighted = picker.move(highlighted, by: -1); return .handled }
            Divider()
            if picker.rows.isEmpty {
                Text(model.labelCatalog.labels.isEmpty ? "No labels yet. Type a name to create one." : "No matching labels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(picker.rows.enumerated()), id: \.element) { index, row in
                                rowView(row, highlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture { highlighted = index; activate(row) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 280)
                    .onChange(of: highlighted) { _, index in
                        if let index { proxy.scrollTo(index) }
                    }
                }
            }
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            fieldFocused = true
            highlighted = picker.initialHighlight(typed: text)
        }
        .onChange(of: text) { _, typed in highlighted = picker.initialHighlight(typed: typed) }
    }

    @ViewBuilder
    private func rowView(_ row: LabelPicker.Row, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            switch row {
            case .label(let label):
                let checked = model.carries(label.id, noteID)
                Image(systemName: "checkmark")
                    .opacity(checked ? 1 : 0)
                    .frame(width: 14)
                Circle().fill(Color(labelHex: label.color)).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.name).lineLimit(1)
                    if !label.details.isEmpty {
                        Text(label.details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            case .create(let name):
                Image(systemName: "plus").frame(width: 14)
                Text("Create label “\(name)”").lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isChecked(row) ? .isSelected : [])
        .accessibilityAction { activate(row) }
    }

    private func isChecked(_ row: LabelPicker.Row) -> Bool {
        if case .label(let label) = row { return model.carries(label.id, noteID) }
        return false
    }

    private func activate(_ row: LabelPicker.Row?) {
        switch row {
        case .label(let label):
            model.toggleLabel(label.id, on: noteID)
        case .create(let name):
            if model.createLabel(named: name, on: noteID) != nil { text = "" }
        case nil:
            NSSound.beep()
        }
    }
}

extension FocusedValues {
    /// The key window's Labels popover for its open note, for Note ▸
    /// Labels…; nil when no note is open.
    @Entry var labelsPopover: Binding<Bool>?
}

/// Note ▸ Labels… (⌃⌘L). No key-binding preset uses ⌃⌘L.
struct NoteCommands: Commands {
    @FocusedValue(\.labelsPopover) private var labelsPopover

    var body: some Commands {
        CommandMenu("Note") {
            Button("Labels…") { labelsPopover?.wrappedValue = true }
                .keyboardShortcut("l", modifiers: [.control, .command])
                .disabled(labelsPopover == nil)
        }
    }
}
