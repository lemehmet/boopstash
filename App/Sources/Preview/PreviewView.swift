import BoopstashCore
import SwiftUI

/// The rendered note (#54), drawn with native views from Core's blocks.
/// No web view, so nothing in a note can reach the network: remote images
/// are named, not fetched, and links open only when clicked.
struct PreviewView: View {
    let markdown: String
    let appearance: EditorAppearance
    /// An attachment's image, for `![](attachment:<id>)`. Called off the
    /// main thread; results are cached, since attachments never change.
    var image: @Sendable (UUID) async -> NSImage? = { _ in nil }
    @Environment(\.colorScheme) private var colorScheme
    @State private var blocks: [PreviewBlock] = []

    private var theme: Theme? { appearance.theme(dark: colorScheme == .dark) }
    private var palette: PreviewPalette { PreviewPalette(theme: theme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block, palette: palette, appearance: appearance, image: image)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .textSelection(.enabled)
        }
        .background(palette.background)
        .foregroundStyle(palette.text)
        // Typing re-renders after a short pause, not on every key.
        .task(id: markdown) {
            if !blocks.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let rendered = await MarkdownPreview.blocks(for: markdown)
            if !Task.isCancelled { blocks = rendered }
        }
        .environment(\.openURL, OpenURLAction { url in
            // Only links Core judged safe carry a URL at all; attachments
            // open in Quick Look's place, the default viewer, never a browser.
            guard url.scheme?.lowercased() != "attachment" else { return .discarded }
            return .systemAction(url)
        })
    }
}

/// An attachment's picture, loaded off the main thread once and cached:
/// attachments never change, so re-rendering never re-reads the disk.
struct AttachmentImage: View {
    let id: UUID
    let alt: String
    let muted: Color
    let load: @Sendable (UUID) async -> NSImage?
    @State private var picture: NSImage?
    @State private var missing = false

    @MainActor static let cache = NSCache<NSUUID, NSImage>()

    var body: some View {
        Group {
            if let picture {
                Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(picture.size.width, 900))
                    .accessibilityLabel(alt)
            } else if missing {
                Label(alt.isEmpty ? "Missing image" : "\(alt) (missing)", systemImage: "photo").foregroundStyle(muted)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: id) {
            if let cached = Self.cache.object(forKey: id as NSUUID) {
                picture = cached
                return
            }
            let loaded = await Task.detached(priority: .userInitiated) { await load(id) }.value
            if let loaded { Self.cache.setObject(loaded, forKey: id as NSUUID) }
            picture = loaded
            missing = loaded == nil
        }
    }
}

/// Colours for the preview: the editor theme's, or the system's.
struct PreviewPalette {
    let theme: Theme?

    var background: Color { theme.map { Color(nsColor: NSColor($0.background)) } ?? Color(nsColor: .textBackgroundColor) }
    var text: Color { theme.map { Color(nsColor: NSColor($0.foreground)) } ?? Color(nsColor: .textColor) }
    var muted: Color { color(for: .comment) }
    var codeBackground: Color { theme.map { Color(nsColor: NSColor($0.selection)) } ?? Color(nsColor: .quaternaryLabelColor).opacity(0.5) }

    func color(for role: HighlightRole) -> Color {
        Color(nsColor: theme.map { NSColor($0.color(for: role)) } ?? SyntaxTheme.systemColor(for: role))
    }
}

struct BlockView: View {
    let block: PreviewBlock
    let palette: PreviewPalette
    let appearance: EditorAppearance
    let image: @Sendable (UUID) async -> NSImage?

    private var bodySize: CGFloat { CGFloat(appearance.fontSize) + 1 }
    private var mono: Font { Font(EditorSettings.font(for: appearance)) }

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(styled(text))
                .font(.system(size: bodySize * [1.7, 1.4, 1.2, 1.1, 1.0, 0.95][level - 1], weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            Text(styled(text)).font(.system(size: bodySize)).lineSpacing(3)
        case .code(_, let code, let highlights):
            ScrollView(.horizontal) {
                Text(highlighted(code, highlights)).font(mono).padding(10)
            }
            .background(palette.codeBackground, in: RoundedRectangle(cornerRadius: 6))
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(palette.muted).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                        BlockView(block: inner, palette: palette, appearance: appearance, image: image)
                    }
                }
                .foregroundStyle(palette.muted)
            }
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Group {
                            if let checked = item.checked {
                                Image(systemName: checked ? "checkmark.square" : "square")
                            } else {
                                Text(ordered ? "\(start + index)." : "•")
                            }
                        }
                        .font(.system(size: bodySize))
                        .frame(minWidth: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, inner in
                                BlockView(block: inner, palette: palette, appearance: appearance, image: image)
                            }
                        }
                    }
                }
            }
        case .table(let header, let rows, let alignments):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        Text(styled(cell)).bold().gridColumnAlignment(alignment(alignments, column))
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(styled(cell)) }
                    }
                }
            }
            .font(.system(size: bodySize))
        case .rule:
            Divider()
        case .image(.attachment(let id, let alt)):
            AttachmentImage(id: id, alt: alt, muted: palette.muted, load: image)
        case .image(.blocked(_, let alt)):
            Label("\(alt.isEmpty ? "Image" : alt) (remote image not loaded)", systemImage: "network.slash")
                .foregroundStyle(palette.muted)
                .help("BoopStash never loads remote images")
        case .rawHTML(let html):
            Text(html).font(mono).foregroundStyle(palette.muted)
        }
    }

    /// Inline code in the editor's font and links in the theme's colour.
    private func styled(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.code) == true { text[run.range].font = mono }
            if run.link != nil { text[run.range].foregroundColor = palette.color(for: .link) }
        }
        return text
    }

    private func highlighted(_ code: String, _ highlights: [PreviewHighlight]) -> AttributedString {
        let attributed = NSMutableAttributedString(string: code)
        for highlight in highlights where NSMaxRange(highlight.range) <= attributed.length {
            attributed.addAttribute(.foregroundColor, value: NSColor(palette.color(for: highlight.role)), range: highlight.range)
        }
        return (try? AttributedString(attributed, including: \.appKit)) ?? AttributedString(code)
    }

    private func alignment(_ alignments: [PreviewAlignment], _ column: Int) -> HorizontalAlignment {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
