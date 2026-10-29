import BoopstashCore
import SwiftUI

struct NoteDetail: View {
    @Bindable var model: AppModel
    let note: Note
    let keymap: Keymap
    let appearance: EditorAppearance
    @State private var title = ""
    @State private var syntax: SyntaxChoice = .automatic
    @AppStorage(PreviewSettings.shownKey) private var previewShown = false
    @AppStorage(PreviewSettings.sideBySideKey) private var sideBySide = true
    /// The text as typed, for the preview; drafts are not observed, so the
    /// editor reports here while a preview shows.
    @State private var liveText: String?
    /// The language the editor highlights now: what the toolbar shows and
    /// what decides whether the preview renders (#151, #152).
    @State private var language: SyntaxLanguage?

    private var canPreview: Bool { MarkdownPreview.canPreview(language) }
    /// This window's script picker, for the toolbar's Run Script.
    @FocusedValue(\.scriptPicker) private var picker

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $title, prompt: Text(note.titleIsUserSet ? "Title" : note.title))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Divider()
            if previewShown && sideBySide {
                HSplitView {
                    editor.frame(minWidth: 240)
                    Group {
                        if canPreview { preview } else { notPreviewable }
                    }
                    .frame(minWidth: 240)
                }
            } else if previewShown && canPreview {
                preview
            } else if previewShown {
                // In place of the editor, but nothing to render: the editor,
                // and a strip saying why (#152).
                VStack(spacing: 0) {
                    notPreviewableStrip
                    Divider()
                    editor
                }
            } else {
                editor
            }
        }
        // A generated title shows as the placeholder and stays out of the
        // field, so typing in the field is always a deliberate rename.
        .toolbar {
            // Frequent commands (#153): the same actions as the menu items,
            // enabled the same way (SwiftUI does not validate them through
            // the responder chain, so they follow the editor's focus).
            ToolbarItemGroup {
                Button("Paste as Markdown", systemImage: "doc.richtext") {
                    NSApp.sendAction(#selector(BoopTextView.pasteAsMarkdown(_:)), to: nil, from: nil)
                }
                .help("Paste as Markdown (⌥⇧⌘V): rich text from the clipboard, as Markdown")
                .disabled(!model.editorHasFocus)
                Button("Run Script", systemImage: "wand.and.stars") {
                    if let editor = model.keyEditor() {
                        model.reloadScripts()
                        picker?.wrappedValue = PickerTarget(editor: editor)
                    }
                }
                .help("Run Script… (⌘B): a Boop script on the selection or the note")
                .disabled(!model.editorHasFocus || picker == nil)
                Toggle(isOn: $previewShown) { Label("Show Preview", systemImage: "eye") }
                    .help("Show Preview (⌥⌘P): the note rendered as Markdown")
                Toggle(isOn: $sideBySide) { Label("Preview Beside the Editor", systemImage: "rectangle.split.2x1") }
                    .help(sideBySide ? "Preview Beside the Editor: on" : "Preview Beside the Editor: off, so the preview replaces the editor")
                    .disabled(!previewShown)
            }
            ToolbarItem {
                LanguageMenu(choice: $syntax, current: language)
            }
        }
        // Compared with the note as it is now, so taking a remote change
        // into these fields is not itself saved as an edit.
        .onChange(of: syntax) {
            if syntax != model.note(id: note.id)?.syntaxChoice { model.setSyntax(note.id, to: syntax) }
        }
        .onAppear {
            title = note.titleIsUserSet ? note.title : ""
            syntax = note.syntaxChoice
            language = currentLanguage()
        }
        .onChange(of: note.id) {
            title = note.titleIsUserSet ? note.title : ""
            liveText = nil
            language = currentLanguage()
        }
        // A language picked in the menu applies at once; the editor reports
        // later changes (detection as the text changes).
        .onChange(of: syntax) { language = currentLanguage() }
        // Changed in iCloud while open (#128): the editor reloads itself;
        // the title, language and preview follow the merged note.
        .onChange(of: model.remoteRevisions[note.id]) {
            guard let merged = model.note(id: note.id) else { return }
            title = merged.titleIsUserSet ? merged.title : ""
            syntax = merged.syntaxChoice
            if liveText != nil { liveText = merged.body }
        }
        .onChange(of: previewShown) { _, shown in
            if !shown { liveText = nil }
        }
        .onChange(of: title) {
            let current = model.note(id: note.id)
            let shown = current.map { $0.titleIsUserSet ? $0.title : "" } ?? ""
            if title != shown { model.rename(note.id, to: title) }
        }
    }
}

extension NoteDetail {
    private var editor: some View {
        // The current draft, not the `note` this view was given: switching
        // the preview layout recreates the editor, and the draft may be
        // newer than what was last saved.
        EditorView(noteID: note.id, revision: model.remoteRevisions[note.id] ?? 0, initialText: model.note(id: note.id)?.body ?? note.body, keymap: keymap, syntax: syntax, appearance: appearance, showMessage: { model.banner = $0 }, jsFormat: { [runner = model.scriptRunner] request in await runner.format(request) }, attachmentURL: { [store = model.store] id in
            (try? store.attachment(id: id)).map { store.fileURL(for: $0) }
        }, storeImage: { [id = note.id] data, type in model.addImage(data, type: type, to: id) }, onFocusChange: { model.editorFocusMayHaveChanged() },
           onLanguage: { language = $0 }) { text in
            model.updateBody(note.id, to: text)
            if previewShown { liveText = text }
        }
    }

    /// The editor's language before it reports one: the setting applied to
    /// the current text.
    private func currentLanguage() -> SyntaxLanguage? {
        syntax.resolve(for: model.note(id: note.id)?.body ?? note.body)
    }

    private var languageName: String { language?.displayName ?? "plain text" }

    /// In the preview's place beside the editor, for a note that is not
    /// Markdown (#152).
    private var notPreviewable: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash").font(.title2).foregroundStyle(.secondary)
            Text("Preview is for Markdown").font(.headline)
            Text("This note is \(languageName).").foregroundStyle(.secondary)
            Button("Treat as Markdown") { syntax = .language(.markdown) }
                .help("Set this note's language to Markdown")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var notPreviewableStrip: some View {
        HStack {
            Image(systemName: "eye.slash").foregroundStyle(.secondary)
            Text("Preview is for Markdown; this note is \(languageName).").foregroundStyle(.secondary)
            Spacer()
            Button("Treat as Markdown") { syntax = .language(.markdown) }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var preview: some View {
        PreviewView(markdown: liveText ?? note.body, appearance: appearance) { [store = model.store] id in
            guard let attachment = try? store.attachment(id: id) else { return nil }
            return NSImage(contentsOf: store.fileURL(for: attachment))
        }
        // Edits made while the preview was hidden are in the draft, not in
        // the copy kept for it: start from the draft each time it shows.
        .onAppear { liveText = model.note(id: note.id)?.body }
    }
}

/// Format ▸ Language for the open note: Automatic (showing what was
/// detected), Plain Text, or a language, for text detection gets wrong or
/// files whose type says nothing (`nginx.conf`).
struct LanguageMenu: View {
    @Binding var choice: SyntaxChoice
    /// What the editor highlights now (#151).
    let current: SyntaxLanguage?

    var body: some View {
        Menu {
            Picker("Language", selection: $choice) {
                Text("Automatic" + (current.map { " (\($0.displayName))" } ?? "")).tag(SyntaxChoice.automatic)
                Text("Plain Text").tag(SyntaxChoice.plain)
                Divider()
                ForEach(SyntaxLanguage.allCases.sorted { $0.displayName < $1.displayName }, id: \.self) { language in
                    Text(language.displayName).tag(SyntaxChoice.language(language))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(label, systemImage: "chevron.left.forwardslash.chevron.right")
                .labelStyle(.titleAndIcon)
        }
        .help(choice == .automatic ? "Language for highlighting: detected from the text" : "Language for highlighting: set for this note")
    }

    /// The language in use; one detected rather than chosen says so.
    private var label: String {
        switch choice {
        case .automatic: "\(current?.displayName ?? "Plain Text") · Auto"
        case .plain: "Plain Text"
        case .language(let language): language.displayName
        }
    }
}
