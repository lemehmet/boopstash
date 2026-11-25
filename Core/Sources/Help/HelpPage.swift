import Foundation

/// Help (#254): the project's README, bundled with the app and drawn by
/// the Markdown preview. Nothing is fetched; a link opens in the browser
/// only when it is clicked.
public enum HelpPage {
    /// The bundled file, `README.md`: the repository's own copy.
    public static let resourceName = "README"
    public static let resourceExtension = "md"

    /// Where the README's relative links lead (`docs/adr/`, `SECURITY.md`,
    /// `LICENSE`): the repository on GitHub, where they point when the
    /// README is read there. Those files are not in the app.
    public static let linkBase = URL(string: "https://github.com/lemehmet/boopstash/blob/main/")!

    /// The README's text, or nil when the file is missing, unreadable or
    /// blank: the page then says so instead of showing nothing.
    public static func markdown(from data: Data?) -> String? {
        guard let data, let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}
