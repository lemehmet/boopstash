import AppKit
import BoopstashCore
import Foundation
import OSLog

/// What Help ▸ Report a Problem… gathers from the system (#185): build and
/// machine facts, this process's own recent log, and an image of a window
/// drawn from its own views. Nothing here needs a permission or an
/// entitlement: no screen capture (ScreenCaptureKit, `CGWindowList…`), no
/// other process's log, no network.
enum LiveDiagnostics {
    /// App Store and TestFlight installs carry a receipt; a Developer ID
    /// build (Homebrew) does not.
    static var distribution: ProblemReport.Distribution {
        #if DEBUG
        return .debug
        #else
        let receipts = Bundle.main.bundleURL.appendingPathComponent("Contents/_MASReceipt", isDirectory: true)
        return FileManager.default.fileExists(atPath: receipts.path) ? .appStore : .developerID
        #endif
    }

    /// The processor's name, such as "Apple M3 Pro".
    static var chip: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    /// This process's log lines from BoopStash's own subsystem since
    /// `since`, oldest first, capped. Reading the store can take a moment:
    /// call it off the main actor.
    nonisolated static func recentLog(since: Date) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
        guard let entries = try? store.getEntries(at: store.position(date: since), matching: predicate) else { return [] }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm:ss.SSS"
        let lines = entries.compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= since }
            .map { "\(time.string(from: $0.date)) \($0.category) \(level($0.level)): \($0.composedMessage)" }
        return ProblemReport.cappedLog(lines)
    }

    private nonisolated static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "log"
        }
    }

    /// The window, toolbar included, as a PNG drawn by its own views. Nil
    /// for a window without content or one too small to draw.
    ///
    /// Drawing a window's views is not what the screen shows on macOS 26 in
    /// two places, both fixed up here without capturing the screen:
    /// - Glass (the sidebar) is composited by the window server and draws
    ///   black, hiding what is on it. Its area is painted with the window
    ///   background and its content drawn on top.
    /// - SwiftUI's own drawing (the note list's rows) lives in layers whose
    ///   tinted contents only the window server renders. Those layers are
    ///   asked to draw themselves again, in place.
    @MainActor
    static func png(of window: NSWindow) -> Data? {
        guard let content = window.contentView,
              let root = content.superview ?? window.contentView,
              root.bounds.width >= 1, root.bounds.height >= 1,
              let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)
        else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return rep.representation(using: .png, properties: [:]) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            for glass in descendants(of: root).compactMap({ $0 as? NSGlassEffectView }) where !glass.isHiddenOrHasHiddenAncestor {
                NSColor.windowBackgroundColor.setFill()
                if glass.isDescendant(of: content) {
                    // The sidebar: the glass and the margin around it, which
                    // draws as a black shadow, then what is on it.
                    imageRect(of: glass.superview ?? glass, in: root).fill()
                    if let inner = glass.contentView { draw(inner, in: root) }
                } else {
                    // A toolbar button's glass, then what is drawn over it:
                    // the toolbar's items are not inside their glass.
                    let area = imageRect(of: glass, in: root)
                    area.fill()
                    redraw(above: glass, within: area, root: root)
                }
            }
            if let layer = content.layer {
                redrawSwiftUILayers(in: layer, content: content, root: root, context: context.cgContext)
            }
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Draws again, in place, each visible layer of SwiftUI's whose
    /// contents only the window server renders.
    @MainActor
    private static func redrawSwiftUILayers(in contentLayer: CALayer, content: NSView, root: NSView, context: CGContext) {
        let origin = imageRect(of: content, in: root)
        var pending = [contentLayer]
        while let layer = pending.popLast() {
            guard !layer.isHidden, layer.opacity > 0 else { continue }
            pending.append(contentsOf: layer.sublayers ?? [])
            guard let contents = layer.contents, String(describing: type(of: contents)).contains("TintedImage") else { continue }
            var rect = layer.convert(layer.bounds, to: contentLayer)
            if content.isFlipped { rect.origin.y = content.bounds.height - rect.maxY }
            context.saveGState()
            context.translateBy(x: origin.minX + rect.minX, y: origin.minY + rect.minY + rect.height)
            context.scaleBy(x: 1, y: -1)
            layer.draw(in: context)
            context.restoreGState()
        }
    }

    /// Draws a view, and what it holds, where it is in the image of `root`.
    @MainActor
    private static func draw(_ view: NSView, in root: NSView, clip: NSRect? = nil) {
        guard !view.isHidden, view.bounds.width >= 1, view.bounds.height >= 1,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        NSGraphicsContext.saveGraphicsState()
        if let clip { clip.clip() }
        image.draw(in: imageRect(of: view, in: root), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws again, within `area`, every view in front of `view`: the
    /// siblings after it and after each of its ancestors, up to `root`.
    @MainActor
    private static func redraw(above view: NSView, within area: NSRect, root: NSView) {
        var current = view
        while current !== root, let parent = current.superview {
            let siblings = parent.subviews
            if let index = siblings.firstIndex(where: { $0 === current }) {
                for sibling in siblings[(index + 1)...] where imageRect(of: sibling, in: root).intersects(area) {
                    draw(sibling, in: root, clip: area)
                }
            }
            current = parent
        }
    }

    /// A view's bounds in the image of `root`, whose origin is bottom left.
    @MainActor
    private static func imageRect(of view: NSView, in root: NSView) -> NSRect {
        var rect = view.convert(view.bounds, to: root)
        if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
        return rect
    }

    @MainActor
    private static func descendants(of root: NSView) -> [NSView] {
        var found: [NSView] = []
        var pending = [root]
        while let view = pending.popLast() {
            found.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return found
    }

    /// The note editor in a window, if it shows one.
    @MainActor
    static func editor(in window: NSWindow) -> BoopTextView? {
        if let focused = window.firstResponder as? BoopTextView { return focused }
        guard let root = window.contentView else { return nil }
        var pending = [root]
        while let view = pending.popLast() {
            if let editor = view as? BoopTextView { return editor }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }
}
