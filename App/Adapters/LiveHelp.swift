import BoopstashCore
import Foundation

/// Help (#254): the README the build bundled, as this platform shows it
/// (#263). Nothing is fetched.
enum LiveHelp {
    #if os(macOS)
    static let platform = HelpPage.Platform.mac
    #else
    static let platform = HelpPage.Platform.ios
    #endif

    /// Read once. Nil when the bundle has no readable README.
    static let markdown: String? = {
        let url = Bundle.main.url(forResource: HelpPage.resourceName, withExtension: HelpPage.resourceExtension)
        return HelpPage.markdown(from: url.flatMap { try? Data(contentsOf: $0) }, for: platform)
    }()
}
