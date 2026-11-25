import BoopstashCore
import Foundation

/// Help (#254): the README the build bundled. Nothing is fetched.
enum LiveHelp {
    /// Read once. Nil when the bundle has no readable README.
    static let markdown: String? = {
        let url = Bundle.main.url(forResource: HelpPage.resourceName, withExtension: HelpPage.resourceExtension)
        return HelpPage.markdown(from: url.flatMap { try? Data(contentsOf: $0) })
    }()
}
