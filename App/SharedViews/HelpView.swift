import BoopstashCore
import SwiftUI

/// Help (#254): the bundled README, drawn by the note preview. No web
/// view, so the page can load nothing; its links open in the browser when
/// clicked, the relative ones at the repository.
struct HelpView: View {
    var markdown: String? = LiveHelp.markdown
    let appearance: EditorAppearance

    var body: some View {
        if let markdown {
            PreviewView(markdown: markdown, appearance: appearance, linkBase: HelpPage.linkBase)
        } else {
            ContentUnavailableView("Help is not available", systemImage: "questionmark.circle",
                                   description: Text("This build of BoopStash has no README."))
        }
    }
}
