import AppKit
import BoopstashCore
import ImageIO
import Quartz

/// Inline image chips (#52). The note's text stays its markdown: each
/// `![](attachment:<id>)` is drawn over by an opaque chip with a thumbnail
/// and a label, while the text underneath is what is saved, searched,
/// copied, undone and moved by line commands. Editing treats a reference
/// as one unit: the selection snaps around it and one delete removes it.
final class ChipView: NSView {
    let reference: NSRange
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}

    init(frame: NSRect, reference: NSRange, label: String?, image: NSImage?, missing: Bool, background: NSColor, fill: NSColor, text: NSColor) {
        self.reference = reference
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        // Nothing drawn outside the reference's own text (#96).
        layer?.masksToBounds = true
        let pill = NSView(frame: bounds.insetBy(dx: 0, dy: 1))
        pill.autoresizingMask = [.width, .height]
        pill.wantsLayer = true
        pill.layer?.backgroundColor = fill.cgColor
        pill.layer?.cornerRadius = 4
        addSubview(pill)
        guard let label else { return }
        let height = max(bounds.height - 4, 8)
        // A segment too narrow for a picture and a few letters (a wrapped
        // reference's first line can be a character wide) stays plain.
        guard bounds.width >= height * 1.4 + 24 else { return }
        var x: CGFloat = 4
        if let image, !missing {
            let thumbnail = NSImageView(frame: NSRect(x: x, y: 2, width: height * 1.4, height: height))
            thumbnail.image = image
            thumbnail.imageScaling = .scaleProportionallyUpOrDown
            addSubview(thumbnail)
            x += height * 1.4 + 4
        } else {
            let icon = NSImageView(frame: NSRect(x: x, y: 2, width: height, height: height))
            icon.image = NSImage(systemSymbolName: missing ? "photo.badge.exclamationmark" : "photo", accessibilityDescription: nil)
            icon.contentTintColor = text
            addSubview(icon)
            x += height + 4
        }
        let field = NSTextField(labelWithString: label)
        field.font = .systemFont(ofSize: max(height * 0.75, 9))
        field.textColor = text
        field.lineBreakMode = .byTruncatingTail
        field.frame = NSRect(x: x, y: 1, width: max(bounds.width - x - 4, 0), height: bounds.height - 2)
        addSubview(field)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        event.clickCount >= 2 ? onDoubleClick() : onClick()
    }
}

extension BoopTextView {
    /// Rebuilds the chips for the current text and layout. Every reference
    /// keeps its range, for editing; only those on screen get a chip, so a
    /// note with many images lays out and looks up only what is visible
    /// (#95). Scrolling rebuilds them.
    func updateChips() {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = []
        chipRanges = []
        guard let layout = textLayoutManager, let content = layout.textContentManager, attachmentURL != nil else { return }
        observeScrollingForChips()
        // The viewport is laid out by the time the view draws; before that
        // (a note just loaded), lay it out now: it is only what is visible.
        if layout.textViewportLayoutController.viewportRange == nil { layout.textViewportLayoutController.layoutViewport() }
        let visible = SyntaxPainter.visibleRange(of: self, in: content)
        let origin = textContainerOrigin
        let theme = activeTheme
        let background = theme.map { NSColor($0.background) } ?? .textBackgroundColor
        let fill = theme.map { NSColor($0.selection) } ?? .quaternaryLabelColor
        let text = theme.map { NSColor($0.foreground) } ?? .labelColor
        for match in AttachmentReference.matches(in: string) {
            chipRanges.append(match.range)
            // Off screen: no layout, no lookup, no view.
            if let visible, NSMaxRange(match.range) < visible.location || match.range.location > NSMaxRange(visible) { continue }
            guard let start = content.location(content.documentRange.location, offsetBy: match.range.location),
                  let end = content.location(start, offsetBy: match.range.length),
                  let range = NSTextRange(location: start, end: end)
            else { continue }
            layout.ensureLayout(for: range)
            var segments: [NSRect] = []
            layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                segments.append(frame.offsetBy(dx: origin.x, dy: origin.y))
                return true
            }
            let url = attachmentURL?(match.id) ?? nil
            let label = url == nil
                ? (match.alt.isEmpty ? "Missing image" : "\(match.alt) (missing)")
                : (match.alt.isEmpty ? "Image" : match.alt)
            for (index, segment) in segments.enumerated() {
                // Only the first segment of a wrapped reference carries the
                // thumbnail and label; the rest just cover its text.
                let chip = ChipView(frame: segment.integral, reference: match.range,
                                    label: index == 0 ? label : nil, image: url.flatMap(thumbnail), missing: url == nil,
                                    background: background, fill: fill, text: text)
                // The editor takes focus first: Copy and Quick Look go
                // through the responder chain, which starts there.
                chip.onClick = { [weak self] in
                    self?.window?.makeFirstResponder(self)
                    self?.setSelectedRange(match.range)
                }
                chip.onDoubleClick = { [weak self] in
                    self?.window?.makeFirstResponder(self)
                    self?.setSelectedRange(match.range)
                    self?.quickLook(url)
                }
                addSubview(chip)
                chipViews.append(chip)
            }
        }
    }

    func scheduleChipUpdate() {
        chipUpdate?.cancel()
        chipUpdate = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            self?.updateChips()
        }
    }

    private func observeScrollingForChips() {
        guard chipScrollObserver == nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        chipScrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleChipUpdate() }
        }
    }

    /// The chip's picture: from the cache, or nil while a small thumbnail
    /// is decoded off the main thread, which then rebuilds the chips (#95).
    /// The full image is never loaded for a chip.
    private func thumbnail(_ url: URL) -> NSImage? {
        if let cached = Self.thumbnails.object(forKey: url as NSURL) { return cached }
        guard !Self.decoding.contains(url) else { return nil }
        Self.decoding.insert(url)
        Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) { Self.downsampled(url, maxPixels: 160) }.value
            Self.decoding.remove(url)
            guard let (image, cost) = decoded else { return }
            Self.thumbnails.setObject(image, forKey: url as NSURL, cost: cost)
            self?.scheduleChipUpdate()
        }
        return nil
    }

    /// A thumbnail at most `maxPixels` on its longer side, read with ImageIO
    /// without decoding the whole image, and its size in bytes.
    nonisolated static func downsampled(_ url: URL, maxPixels: Int) -> (NSImage, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return (image, cgImage.bytesPerRow * cgImage.height)
    }

    /// The reference a position falls strictly inside, if any.
    func chipRange(containing location: Int) -> NSRange? {
        chipRanges.first { location > $0.location && location < NSMaxRange($0) }
    }

    /// A selection never ends inside a reference: a caret moves to the side
    /// it came from, a range grows to cover the reference.
    func snapped(_ ranges: [NSValue], from previous: NSRange) -> [NSValue] {
        guard !chipRanges.isEmpty else { return ranges }
        return ranges.map { value in
            var range = value.rangeValue
            if range.length == 0 {
                if let chip = chipRange(containing: range.location) {
                    range.location = previous.location <= chip.location ? NSMaxRange(chip) : chip.location
                }
            } else {
                if let chip = chipRange(containing: range.location) {
                    range.length += range.location - chip.location
                    range.location = chip.location
                }
                if let chip = chipRange(containing: NSMaxRange(range)) {
                    range.length = NSMaxRange(chip) - range.location
                }
            }
            return NSValue(range: range)
        }
    }

    // MARK: Quick Look

    func quickLook(_ url: URL?) {
        guard let url, let panel = QLPreviewPanel.shared() else { return }
        quickLookSource = QuickLookSource(url: url)
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLookSource != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookSource
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        quickLookSource = nil
    }
}

/// Quick Look's data source: the one image a double-clicked chip shows.
final class QuickLookSource: NSObject, QLPreviewPanelDataSource, Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL }
}
