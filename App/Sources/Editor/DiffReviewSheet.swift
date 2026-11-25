import AppKit
import BoopstashCore
import SwiftUI

/// A change shown for review before it is applied (#245): what would be
/// removed and added, with Keep and Discard. It knows nothing of where the
/// change came from; the editor that asked decides what Keep does.
struct DiffReviewView: View {
    /// What made the change, for the heading: a script's name.
    let title: String
    let content: DiffReviewContent
    let keep: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DiffReviewHeader(title: title, summary: content.summary)
            Divider()
            DiffReviewBody(content: content)
            Divider()
            DiffReviewButtons(keep: keep, discard: discard)
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 320, idealHeight: 520)
        .onExitCommand(perform: discard)
    }
}

private struct DiffReviewHeader: View {
    let title: String
    let summary: TextDiff.Summary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            Text(summary.description).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct DiffReviewButtons: View {
    let keep: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Discard", role: .cancel, action: discard)
                .keyboardShortcut(.cancelAction)
            Button("Keep", action: keep)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}

private struct DiffReviewBody: View {
    let content: DiffReviewContent

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(content.parts) { part in
                    DiffReviewPart(part: part, first: part.id == content.parts.first?.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct DiffReviewPart: View {
    let part: DiffReviewContent.Part
    let first: Bool

    var body: some View {
        ForEach(Array(part.hunks.enumerated()), id: \.offset) { index, hunk in
            if !(first && index == 0) { DiffReviewGap() }
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                DiffReviewRow(line: line)
            }
        }
    }
}

/// Between two hunks: lines left out because nothing in them changes.
private struct DiffReviewGap: View {
    var body: some View {
        Text("⋯")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Color(nsColor: .windowBackgroundColor))
            .accessibilityLabel("Unchanged lines left out")
    }
}

/// One line: its numbers before and after, a mark that says what happened
/// to it (never colour alone), and its text with the changed words marked.
private struct DiffReviewRow: View {
    let line: TextDiff.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            DiffReviewNumber(number: line.oldNumber)
            DiffReviewNumber(number: line.newNumber)
            Text(DiffReviewStyle.mark(line.kind))
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(DiffReviewStyle.text(of: line))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            if line.endingChanged {
                Text(line.ending.mark)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
            }
            Spacer(minLength: 12)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffReviewStyle.background(line.kind))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.spokenDescription)
    }
}

private struct DiffReviewNumber: View {
    let number: Int?

    var body: some View {
        Text(number.map(String.init) ?? "")
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 4)
    }
}

/// How a diff line looks. Pure, so the hosted tests can check the marks
/// without drawing anything.
enum DiffReviewStyle {
    static func mark(_ kind: TextDiff.Kind) -> String {
        switch kind {
        case .unchanged: " "
        case .removed: "−"
        case .added: "+"
        }
    }

    static func background(_ kind: TextDiff.Kind) -> Color {
        switch kind {
        case .unchanged: .clear
        case .removed: .red.opacity(0.14)
        case .added: .green.opacity(0.14)
        }
    }

    /// The line's text with the words that changed on a stronger
    /// background and underlined, so they show without colour too.
    static func text(of line: TextDiff.Line) -> AttributedString {
        let text = NSMutableAttributedString(string: line.text.isEmpty ? " " : line.text)
        guard line.kind != .unchanged else { return AttributedString(text) }
        let tint: NSColor = line.kind == .removed ? .systemRed : .systemGreen
        let length = (line.text as NSString).length
        for range in line.changes where NSMaxRange(range) <= length {
            text.addAttribute(.backgroundColor, value: tint.withAlphaComponent(0.32), range: range)
            text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        return AttributedString(text)
    }
}

/// Shows a review as a sheet on a window.
@MainActor
enum DiffReviewPresenter {
    /// The sheet, already attached to `window`. Ending it is the caller's
    /// to do, from `keep` or `discard`.
    static func present(title: String, content: DiffReviewContent, over window: NSWindow,
                        keep: @escaping () -> Void, discard: @escaping () -> Void) -> NSWindow {
        let view = DiffReviewView(title: title, content: content, keep: keep, discard: discard)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = title
        sheet.contentViewController = NSHostingController(rootView: view)
        sheet.setContentSize(NSSize(width: 720, height: 520))
        window.beginSheet(sheet)
        return sheet
    }
}
