import BoopstashCore
import SwiftUI

/// Scripts ▸ Run Script… (⌘B, as in Boop): type to filter, ↑ and ↓ to
/// choose, Return to run on the selection or the whole note, Escape to
/// close.
struct ScriptPicker: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var highlighted: BoopScript.ID?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var results: [BoopScript] {
        ScriptSearch.rank(model.scriptLibrary.scripts, for: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Run a script…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($searchFocused)
                .onSubmit(runHighlighted)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            Divider()
            ScrollViewReader { proxy in
                List(results, selection: $highlighted) { script in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(script.name)
                        if !script.description.isEmpty {
                            Text(script.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(script.id)
                    .id(script.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { run(script) }
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .frame(width: 460, height: 380)
        .onAppear {
            searchFocused = true
            highlighted = results.first?.id
        }
        .onChange(of: query) { _, _ in highlighted = results.first?.id }
        .onExitCommand { dismiss() }
    }

    private func move(_ step: Int) {
        let ids = results.map(\.id)
        guard !ids.isEmpty else { return }
        let current = highlighted.flatMap { ids.firstIndex(of: $0) } ?? -1
        highlighted = ids[max(0, min(ids.count - 1, current + step))]
    }

    private func runHighlighted() {
        guard let script = results.first(where: { $0.id == highlighted }) ?? results.first else {
            NSSound.beep()
            return
        }
        run(script)
    }

    private func run(_ script: BoopScript) {
        dismiss()
        model.run(script)
    }
}
