import AppKit
import BoopstashCore

/// The Services menu item "Save to Boopstash": any app's selected text
/// becomes a note. The text arrives on a pasteboard the system fills for
/// this one request, so the same type policy applies as for the clipboard.
@MainActor
final class ServicesProvider: NSObject {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    /// Named by `NSMessage` in Info.plist.
    @objc func saveSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        model.capture(from: pasteboard, origin: .service)
    }
}
