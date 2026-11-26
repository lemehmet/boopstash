import AppKit
import BoopstashCore
import SwiftUI

/// What the workbench's window remembers between uses (#285): its frame
/// and the split between the script and the diff. One of each for the
/// app, not one per note: the next workbench opens where the last one was.
/// What a stored value means, and what is done with a bad one, is Core's
/// (`ScriptWorkbenchLayout`).
@MainActor
struct ScriptWorkbenchLayoutStore {
    static let frameKey = "ScriptWorkbenchFrame"
    static let splitKey = "ScriptWorkbenchSplit"

    let defaults: UserDefaults

    static var standard: ScriptWorkbenchLayoutStore { ScriptWorkbenchLayoutStore(defaults: .standard) }

    var frame: CGRect? {
        get { ScriptWorkbenchLayout.frame(stored: (defaults.array(forKey: Self.frameKey) as? [NSNumber])?.map(\.doubleValue)) }
        nonmutating set {
            if let newValue {
                defaults.set(ScriptWorkbenchLayout.stored(newValue), forKey: Self.frameKey)
            } else {
                defaults.removeObject(forKey: Self.frameKey)
            }
        }
    }

    var split: Double {
        get { ScriptWorkbenchLayout.split(stored: defaults.object(forKey: Self.splitKey) as? Double) }
        nonmutating set { defaults.set(newValue, forKey: Self.splitKey) }
    }
}

/// The workbench's window (#285): a window of its own, not a sheet on the
/// note's, so it can be moved to any display, sized past the note's
/// window, zoomed and made full screen. It is still one note's: the
/// session closes it with that note.
@MainActor
final class ScriptWorkbenchWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    /// The workbench this is the window of: how a window is known to be
    /// one note's workbench (#289). Weak: the session holds this.
    private(set) weak var session: ScriptWorkbenchSession?
    private let layout: ScriptWorkbenchLayoutStore
    /// The window is closing or closed: by its close button, or by `close`.
    private var closing = false
    /// From the start of the way into full screen to the end of the way
    /// out: the frames in between are not the user's.
    private var inFullScreen = false
    private let onClose: () -> Void

    /// - Parameters:
    ///   - noteWindow: the note's window, whose screen a first opening is on.
    ///   - onClose: the window was closed by the user.
    init(session: ScriptWorkbenchSession, title: String, layout: ScriptWorkbenchLayoutStore, noteWindow: NSWindow?,
         onClose: @escaping () -> Void) {
        self.session = session
        self.layout = layout
        self.onClose = onClose
        let size = ScriptWorkbenchLayout.defaultSize
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = title
        // Full screen in a space of its own; a window that can be resized
        // gets this from AppKit, but it is what the window is for.
        window.collectionBehavior.insert(.fullScreenPrimary)
        // One script, one window (tabs are out of scope), and it is not
        // brought back at launch: it belongs to a note that was open.
        window.tabbingMode = .disallowed
        window.isRestorable = false
        let hosting = NSHostingController(rootView: ScriptWorkbenchView(session: session))
        // The view's minimum is the window's; its ideal size is not, or the
        // window would snap back to it.
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.contentMinSize = ScriptWorkbenchLayout.minimumSize
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: ScriptWorkbenchLayout.minimumSize)).size
        let preferred = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        let frame = ScriptWorkbenchLayout.frame(
            remembered: layout.frame, screens: NSScreen.screens.map(\.visibleFrame),
            home: (noteWindow?.screen ?? NSScreen.main)?.visibleFrame, minimum: minimum, preferred: preferred)
        window.setFrame(frame, display: false)
        window.delegate = self
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    /// Asked for again: the window comes forward, out of the Dock if it
    /// was there.
    func bringForward() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window. Its frame is remembered as it goes.
    func close() {
        guard !closing else { return }
        closing = true
        remember()
        window.delegate = nil
        window.close()
        release()
    }

    /// The window's content holds the session, which holds this: let go
    /// once the close has run its course, not in the middle of it.
    private func release() {
        DispatchQueue.main.async { [window] in
            window.contentViewController = nil
        }
    }

    private func remember() {
        guard !inFullScreen, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        layout.frame = window.frame
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { remember() }
    func windowDidResize(_ notification: Notification) { remember() }
    func windowWillEnterFullScreen(_ notification: Notification) { inFullScreen = true }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { inFullScreen = false }
    func windowDidExitFullScreen(_ notification: Notification) { inFullScreen = false }

    /// The close button, or ⌘W.
    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }
        closing = true
        remember()
        onClose()
        release()
    }
}
