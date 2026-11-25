import BoopstashCore
import SwiftUI

/// Settings ▸ Model (ADR 0014): a language model the user runs
/// themselves, which the script workbench can then ask for a first draft
/// of a script. Empty by default; with no base URL the feature does not
/// exist and nothing is ever requested.
struct ModelSettings: View {
    let model: AppModel?

    var body: some View {
        if let store: ModelEndpointStore = model?.modelEndpoint {
            ModelSettingsForm(store: store)
        } else {
            Text("Model settings are not available.").foregroundStyle(.secondary).padding()
        }
    }
}

private struct ModelSettingsForm: View {
    let store: ModelEndpointStore
    @State private var showsGeneration = false

    var body: some View {
        Form {
            Section("Your model") {
                ModelSettingsIntro()
                ModelEndpointField(store: store)
                ModelKeyField(store: store)
                ModelNameField(store: store)
                ModelTestRow(store: store)
            }
            Section {
                DisclosureGroup("Generation settings", isExpanded: $showsGeneration) {
                    ModelGenerationFields(store: store)
                }
            }
        }
        .formStyle(.grouped)
        // Reads the Keychain, to say whether a key is saved. No request.
        .onAppear { store.refreshKeyState() }
    }
}

private struct ModelSettingsIntro: View {
    var body: some View {
        Text("If you run a language model yourself, the script workbench can ask it for a first draft of a script. It speaks the OpenAI-compatible API that llama.cpp, llama-swap, Ollama, LM Studio, vLLM and MLX servers offer. BoopStash picks no service and ships no key; leave the base URL empty and nothing is ever sent.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("What is sent, and only when you choose Generate: your instruction, the sample the workbench shows, and any lines you marked as examples. Nothing else of the note, and no other note. The reply goes into the workbench's editor and runs only when you run it.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A text field that hands its text over when Return is pressed or the
/// field is left, not on every keystroke.
private struct CommitField: View {
    let title: String
    let prompt: String
    let value: String
    var monospaced = false
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { text = value }
            .onSubmit { commit(text) }
            .onChange(of: focused) { if !focused, text != value { commit(text) } }
    }
}

/// The base URL, with the mark that says what goes there. Entering it
/// fetches the service's model list.
private struct ModelEndpointField: View {
    let store: ModelEndpointStore

    var body: some View {
        HStack {
            CommitField(title: "Base URL", prompt: "http://localhost:8080", value: store.settings.baseURL) { (text: String) in
                if store.setBaseURL(text) { store.refreshModels() }
            }
            if let indicator: ModelEndpointIndicator = store.indicator {
                ModelEndpointMark(indicator: indicator)
            }
        }
        if let problem: String = store.addressProblem {
            Text(problem).font(.caption).foregroundStyle(.red)
        } else if let indicator: ModelEndpointIndicator = store.indicator {
            Text(indicator.details).font(.caption).foregroundStyle(indicator.isStrong ? Color.orange : Color.secondary)
        }
    }
}

/// The API key: typed here, kept in the Keychain, never shown again.
private struct ModelKeyField: View {
    let store: ModelEndpointStore
    @State private var key = ""

    var body: some View {
        HStack {
            SecureField("API key (optional)", text: $key, prompt: Text(store.hasKey ? "Saved in your Keychain" : "None"))
                .onSubmit { save() }
            Button("Save") { save() }.disabled(key.isEmpty)
            Button("Remove") {
                key = ""
                store.setKey("")
            }
            .disabled(!store.hasKey)
        }
        Text(store.keyProblem ?? "The key is kept in your Keychain for this endpoint only, and sent to it as the Authorization header. It is never written to a note, a log or a problem report.")
            .font(.caption)
            .foregroundStyle(store.keyProblem == nil ? Color.secondary : Color.red)
    }

    private func save() {
        guard !key.isEmpty else { return }
        store.setKey(key)
        if store.keyProblem == nil { key = "" }
    }
}

/// The model: picked from the service's own list, or typed when there is
/// no list.
private struct ModelNameField: View {
    let store: ModelEndpointStore

    var body: some View {
        HStack {
            if let options: [ModelList.Option] = store.modelOptions {
                Picker("Model", selection: Binding(get: { store.settings.model }, set: { store.setModel($0) })) {
                    if store.settings.model.isEmpty { Text("Choose a model").tag("") }
                    ForEach(options) { (option: ModelList.Option) in
                        Text(option.title).tag(option.name)
                    }
                }
            } else {
                CommitField(title: "Model", prompt: "The model's name", value: store.settings.model) { (text: String) in
                    store.setModel(text)
                }
            }
            if store.isListing { ProgressView().controlSize(.small) }
            Button("Refresh") { store.refreshModels() }
                .disabled(store.address == nil || store.isListing)
                .help("Fetch the model list from the service. This sends your key, if you set one, and nothing else.")
        }
        if let note: String = store.listNote {
            Text(note).font(.caption).foregroundStyle(store.listProblem == nil ? Color.secondary : Color.red)
        }
    }
}

private struct ModelTestRow: View {
    let store: ModelEndpointStore

    var body: some View {
        HStack {
            Button("Test") { store.test() }
                .disabled(store.address == nil || store.isTesting)
                .help("Ask the model for a small script, with an instruction and a sample of BoopStash's own. None of your text is sent.")
            if store.isTesting { ProgressView().controlSize(.small) }
            if let result: ModelEndpointStore.TestResult = store.testResult {
                Text(result.text).font(.caption).foregroundStyle(result.passed ? Color.secondary : Color.red)
            }
        }
    }
}

/// The generation settings, each with a default, and Reset to Defaults.
private struct ModelGenerationFields: View {
    let store: ModelEndpointStore

    var body: some View {
        Text("Prefer a model that does not reason first, or switch its reasoning off with the extra request fields below. A model that reasons first can spend its whole reply, or minutes, before it writes a line; the context is better spent on your text and examples.")
            .font(.caption)
            .foregroundStyle(.secondary)
        ForEach(ModelGenerationSettings.Field.allCases) { (field: ModelGenerationSettings.Field) in
            ModelGenerationField(store: store, field: field)
        }
        ModelExtraFieldsRow(store: store)
        Button("Reset to Defaults") { store.resetGeneration() }
            .disabled(store.settings.generation == .defaults)
    }
}

private struct ModelGenerationField: View {
    let store: ModelEndpointStore
    let field: ModelGenerationSettings.Field

    var body: some View {
        CommitField(title: field.label, prompt: ModelGenerationSettings.defaults.text(field),
                    value: store.settings.generation.text(field)) { (text: String) in
            store.enter(text, in: field)
        }
        if let note: String = store.notes[field] {
            Text(note).font(.caption).foregroundStyle(.orange)
        }
    }
}

/// The extra request fields, with the mark that lists how each kind of
/// server spells "reasoning off": its hover text and accessibility label,
/// and a menu that fills the field.
private struct ModelExtraFieldsRow: View {
    let store: ModelEndpointStore

    var body: some View {
        HStack {
            CommitField(title: "Extra request fields", prompt: "{ }", value: store.settings.generation.extraFields,
                        monospaced: true) { (text: String) in
                store.setExtraFields(text)
            }
            Menu(ModelDialect.mark) {
                ForEach(ModelDialect.all) { (dialect: ModelDialect) in
                    Button("\(dialect.name): \(dialect.fields)") { store.setExtraFields(dialect.fields) }
                        .help(dialect.note)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(ModelDialect.help)
            .accessibilityLabel(ModelDialect.help)
        }
        if let problem: String = store.extraFieldsProblem {
            Text("Not used: \(problem)").font(.caption).foregroundStyle(.red)
        } else {
            Text("A JSON object merged into each request, for what your server needs. Empty for none.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
