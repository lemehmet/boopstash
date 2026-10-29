import AppKit
import BoopstashCore

/// Reads the general pasteboard, only ever in response to a user action
/// (ADR 0001): a menu item, its shortcut, or a paste.
enum ClipboardCapture {
    enum Outcome: Equatable {
        case text(String)
        case refused(CapturePolicy.Decision)
        case empty
    }

    @MainActor
    static func read(from pasteboard: NSPasteboard = .general) -> Outcome {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let decision = CapturePolicy.decide(types: types)
        guard decision == .accept else { return .refused(decision) }
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .empty }
        return .text(text)
    }
}

/// Remembers the last app other than BoopStash to come to the front, so a
/// capture can say where its text most likely came from. Uses only
/// NSWorkspace's activation notifications: no Accessibility permission, no
/// window titles.
@MainActor
final class SourceAppTracker {
    private(set) var lastOtherApp: (bundleID: String?, name: String?)?
    private var observer: NSObjectProtocol?

    init() {
        if let app = NSWorkspace.shared.frontmostApplication { note(app) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app { self?.note(app) }
            }
        }
    }

    private func note(_ app: NSRunningApplication) {
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastOtherApp = (app.bundleIdentifier, app.localizedName)
    }
}
