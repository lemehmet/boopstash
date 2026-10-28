import BoopstashCore
import SwiftUI

struct NoteDetail: View {
    @Bindable var model: AppModel
    let note: Note
    let keymap: Keymap
    @State private var title = ""
    @State private var syntax: SyntaxChoice = .automatic

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $title, prompt: Text(note.titleIsUserSet ? "Title" : note.title))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Divider()
            EditorView(noteID: note.id, initialText: note.body, keymap: keymap, syntax: syntax, showMessage: { model.banner = $0 }, onFocusChange: { model.editor($0, hasFocus: $1) }) { text in
                model.updateBody(note.id, to: text)
            }
        }
        // A generated title shows as the placeholder and stays out of the
        // field, so typing in the field is always a deliberate rename.
        .toolbar {
            ToolbarItem {
                LanguageMenu(choice: $syntax, detected: SyntaxLanguage.detect(note.body))
            }
        }
        .onChange(of: syntax) { model.setSyntax(note.id, to: syntax) }
        .onAppear {
            title = note.titleIsUserSet ? note.title : ""
            syntax = note.syntaxChoice
        }
        .onChange(of: note.id) {
            title = note.titleIsUserSet ? note.title : ""
        }
        .onChange(of: title) {
            if title.isEmpty || title != note.title { model.rename(note.id, to: title) }
        }
    }
}

/// Format ▸ Language for the open note: Automatic (showing what was
/// detected), Plain Text, or a language, for text detection gets wrong or
/// files whose type says nothing (`nginx.conf`).
struct LanguageMenu: View {
    @Binding var choice: SyntaxChoice
    let detected: SyntaxLanguage?

    var body: some View {
        Menu {
            Picker("Language", selection: $choice) {
                Text("Automatic" + (detected.map { " (\($0.displayName))" } ?? "")).tag(SyntaxChoice.automatic)
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
        .help("Language for highlighting")
    }

    private var label: String {
        switch choice {
        case .automatic: detected?.displayName ?? "Plain Text"
        case .plain: "Plain Text"
        case .language(let language): language.displayName
        }
    }
}
