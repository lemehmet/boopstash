import BoopstashCore
import SwiftUI

struct NoteDetail: View {
    @Bindable var model: AppModel
    let note: Note
    let keymap: Keymap
    @State private var title = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $title, prompt: Text(note.titleIsUserSet ? "Title" : note.title))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            Divider()
            EditorView(noteID: note.id, initialText: note.body, keymap: keymap, showMessage: { model.banner = $0 }) { text in
                model.updateBody(note.id, to: text)
            }
        }
        // A generated title shows as the placeholder and stays out of the
        // field, so typing in the field is always a deliberate rename.
        .onAppear { title = note.titleIsUserSet ? note.title : "" }
        .onChange(of: note.id) {
            title = note.titleIsUserSet ? note.title : ""
        }
        .onChange(of: title) {
            if title.isEmpty || title != note.title { model.rename(note.id, to: title) }
        }
    }
}
