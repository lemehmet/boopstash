import AppKit
import BoopstashCore

/// Colours the editor's text from Core's `SyntaxEngine` (ADR 0006).
///
/// Every edit is sent, in order, through one queue to the engine actor,
/// which reparses incrementally off the main thread. Painting asks the
/// engine for the visible range only and applies TextKit 2 rendering
/// attributes, which colour without touching storage: no undo entries, no
/// change notifications, nothing saved. A paint is skipped unless the engine
/// has caught up with the text on screen, so stale ranges are never drawn.
@MainActor
final class SyntaxPainter {
    private weak var view: NSTextView?
    private(set) var language: SyntaxLanguage?
    /// The note's setting: detect, plain, or a forced language.
    private(set) var choice: SyntaxChoice = .automatic
    private var engine: SyntaxEngine?

    private enum Operation {
        case reset(SyntaxChoice, String, version: Int)
        case edit(TextChange, String, version: Int)
    }
    private let operations: AsyncStream<Operation>.Continuation
    private var consumer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Text versions as the view sees them and as the engine has applied
    /// them; painting needs the two to agree.
    private var shownVersion = 0
    private var appliedVersion = 0
    private var loading = false
    private var paintPending = false
    /// A paint was asked for while one was in flight (a scroll, say); run
    /// one more when it finishes so the newest viewport is coloured.
    private var repaintRequested = false
    private var detection: Task<Void, Never>?

    /// Called after each paint; tests use it to observe the view between the
    /// paint and the next display.
    var didPaint: (() -> Void)?

    /// Characters painted beyond the visible range, so a short scroll shows
    /// colour before the next paint lands.
    static let margin = 4_000

    init() {
        let (stream, continuation) = AsyncStream<Operation>.makeStream()
        operations = continuation
        consumer = Task { [weak self] in
            for await operation in stream {
                await self?.handle(operation)
            }
        }
    }

    isolated deinit {
        operations.finish()
        consumer?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to view: NSTextView) {
        self.view = view
        if let storage = view.textStorage {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
            ) { [weak self] notification in
                guard let storage = notification.object as? NSTextStorage,
                      storage.editedMask.contains(.editedCharacters)
                else { return }
                let edited = storage.editedRange
                let delta = storage.changeInLength
                let text = storage.string
                MainActor.assumeIsolated { self?.textDidChange(edited: edited, delta: delta, text: text) }
            })
        }
        if let clip = view.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePaint() }
            })
        }
    }

    /// A new document: resolve its language and parse it from scratch. Call
    /// after setting the view's text.
    func load(_ text: String, choice: SyntaxChoice = .automatic) {
        detection?.cancel()
        self.choice = choice
        shownVersion += 1
        operations.yield(.reset(choice, text, version: shownVersion))
    }

    /// Format ▸ Language for the open note.
    func setChoice(_ choice: SyntaxChoice) {
        guard choice != self.choice, let text = view?.string else { return }
        load(text, choice: choice)
    }

    /// Wraps a programmatic replacement of the whole text, so the storage
    /// notification it causes is not also sent as an edit.
    func replacingDocument(_ body: () -> Void) {
        loading = true
        body()
        loading = false
    }

    private func textDidChange(edited: NSRange, delta: Int, text: String) {
        guard !loading else { return }
        shownVersion += 1
        let old = NSRange(location: edited.location, length: edited.length - delta)
        operations.yield(.edit(TextChange(range: old, replacementLength: edited.length), text, version: shownVersion))
        scheduleDetection()
    }

    /// A note's language can change as it is written (an empty note gets
    /// JSON pasted in). Re-detect once typing pauses; reset only on change.
    private func scheduleDetection() {
        guard choice == .automatic else { return }
        detection?.cancel()
        detection = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, let text = self.view?.string else { return }
            // Detection reads up to 64 KB with regular expressions: off the
            // main thread, like parsing.
            let detected = await Task.detached(priority: .userInitiated) { SyntaxLanguage.detect(text) }.value
            guard !Task.isCancelled, self.choice == .automatic, detected != self.language else { return }
            self.shownVersion += 1
            self.operations.yield(.reset(.automatic, text, version: self.shownVersion))
        }
    }

    private func handle(_ operation: Operation) async {
        switch operation {
        case .reset(let choice, let text, let version):
            let language = await Task.detached(priority: .userInitiated) { choice.resolve(for: text) }.value
            if language != self.language || engine == nil {
                self.language = language
                engine = language.flatMap { try? SyntaxEngine(language: $0) }
            }
            if let engine { _ = await engine.reset(text) }
            appliedVersion = version
        case .edit(let change, let text, let version):
            if let engine { _ = await engine.apply(change, newText: text) }
            appliedVersion = version
        }
        schedulePaint()
    }

    private func schedulePaint() {
        guard !paintPending else {
            repaintRequested = true
            return
        }
        paintPending = true
        Task { [weak self] in
            await self?.paint()
            guard let self else { return }
            self.paintPending = false
            if self.repaintRequested {
                self.repaintRequested = false
                self.schedulePaint()
            }
        }
    }

    private func paint() async {
        guard let view, let layout = view.textLayoutManager, let content = layout.textContentManager else { return }
        let length = (view.string as NSString).length
        guard let engine else {
            // Clearing is a paint too: without the redraw, Plain Text left the
            // previous colours on screen (#32).
            layout.removeRenderingAttribute(.foregroundColor, for: layout.documentRange)
            Self.markForRedisplay(view)
            didPaint?()
            return
        }
        guard appliedVersion == shownVersion else { return } // a newer edit will paint
        let visible = Self.visibleRange(of: view, in: content) ?? NSRange(location: 0, length: min(length, 8_000))
        let start = max(visible.location - Self.margin, 0)
        let window = NSRange(location: start, length: min(NSMaxRange(visible) + Self.margin, length) - start)
        let version = shownVersion
        let (_, highlights) = await engine.highlights(in: window)
        guard version == shownVersion, appliedVersion == shownVersion else { return }

        layout.removeRenderingAttribute(.foregroundColor, for: layout.documentRange)
        for highlight in highlights {
            guard let color = SyntaxTheme.color(for: highlight.name) else { continue }
            let range = NSIntersectionRange(highlight.range, window)
            guard range.length > 0, let textRange = Self.textRange(range, in: content) else { continue }
            layout.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
        }
        Self.markForRedisplay(view)
        didPaint?()
    }

    /// TextKit 2 draws each paragraph in its own subview and does not
    /// redraw them when rendering attributes change, nor when the text view
    /// itself is marked; they kept the old colours until something else
    /// relaid them out (seen hands-on: a language change showed only after
    /// switching notes). Marking every descendant redraws them, and a redraw
    /// uses the current rendering attributes.
    static func markForRedisplay(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(markForRedisplay)
    }

    static func visibleRange(of view: NSTextView, in content: NSTextContentManager) -> NSRange? {
        guard let viewport = view.textLayoutManager?.textViewportLayoutController.viewportRange else { return nil }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let length = content.offset(from: viewport.location, to: viewport.endLocation)
        return NSRange(location: start, length: length)
    }

    static func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
        guard let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }
}

/// Capture names to colours. System colours adapt to light and dark mode;
/// anything unlisted keeps the text colour.
enum SyntaxTheme {
    static func color(for capture: String) -> NSColor? {
        let parts = capture.split(separator: ".")
        switch parts.first {
        case "comment": return .secondaryLabelColor
        case "string":
            return parts.contains("escape") || parts.contains("regex") ? .systemOrange : .systemRed
        case "character", "escape": return .systemOrange
        case "number", "float", "boolean", "constant": return .systemPurple
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass", "preproc", "define":
            return .systemPink
        case "function", "method", "constructor": return .systemTeal
        case "type", "namespace", "module": return .systemCyan
        case "property", "field", "attribute", "label", "tag": return .systemBlue
        case "variable": return parts.contains("builtin") ? .systemOrange : nil
        case "text", "markup":
            if parts.contains("title") || parts.contains("heading") { return .systemBlue }
            if parts.contains("literal") || parts.contains("raw") { return .systemRed }
            if parts.contains("uri") || parts.contains("link") { return .linkColor }
            return nil
        case "diff":
            if parts.contains("plus") { return .systemGreen }
            if parts.contains("minus") { return .systemRed }
            return .systemBlue
        default: return nil
        }
    }
}
