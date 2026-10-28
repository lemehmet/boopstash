import AppKit
import SwiftUI

@main
struct EditorSpikeApp: App {
    var body: some Scene {
        WindowGroup("Editor spike") {
            SpikeWindow()
                .frame(minWidth: 700, minHeight: 500)
        }
    }
}

enum Sample: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case json = "1 MB JSON"
    var id: Self { self }
}

struct SpikeWindow: View {
    @State private var sample: Sample = .markdown
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            SpikeEditor(sample: sample, status: $status)
            Divider()
            Text(status)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .toolbar {
            Picker("Sample", selection: $sample) {
                ForEach(Sample.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Button("Insert image chip") {
                NotificationCenter.default.post(name: .insertChip, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let insertChip = Notification.Name("insertChip")
}

struct SpikeEditor: NSViewRepresentable {
    let sample: Sample
    @Binding var status: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = SpikeTextView.make()
        context.coordinator.attach(view, status: $status)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.load(sample)
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var view: SpikeTextView?
        private var loaded: Sample?
        private var status: Binding<String>?
        private var highlighter: JSONHighlighter?
        private var observers: [NSObjectProtocol] = []

        func attach(_ view: SpikeTextView, status: Binding<String>) {
            self.view = view
            self.status = status
            view.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: view.enclosingScrollView?.contentView, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.repaint() } })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification, object: view, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.reparse() } })
            observers.append(NotificationCenter.default.addObserver(
                forName: .insertChip, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.insertChip() } })
        }

        func load(_ sample: Sample) {
            guard let view, sample != loaded else { return }
            loaded = sample
            switch sample {
            case .markdown:
                highlighter = nil
                view.string = Samples.markdown
            case .json:
                highlighter = try? JSONHighlighter()
                view.string = Samples.largeJSON()
                reparse()
            }
            view.setSelectedRange(NSRange(location: 0, length: 0))
            report("loaded")
        }

        private func reparse() {
            guard let view, let highlighter else { return report("edited") }
            let start = ContinuousClock.now
            highlighter.parse(view.string)
            let parse = ContinuousClock.now - start
            repaint()
            report("full parse \(parse.formatted(.units(allowed: [.milliseconds])))")
        }

        private func repaint() {
            guard let view, let highlighter, let layout = view.textLayoutManager,
                  let viewport = layout.textViewportLayoutController.viewportRange,
                  let content = layout.textContentManager else { return }
            let start = content.offset(from: content.documentRange.location, to: viewport.location)
            let length = content.offset(from: viewport.location, to: viewport.endLocation)
            highlighter.paint(view, visible: NSRange(location: start, length: length))
        }

        private func insertChip() {
            guard let view else { return }
            view.textStorage?.insert(Attachments.chip(), at: view.selectedRange().location)
            report("chip inserted")
        }

        private func report(_ event: String) {
            guard let view else { return }
            let engine = view.textLayoutManager != nil ? "TextKit 2" : "TextKit 1 (fell back!)"
            let text = "\(engine) · \(view.string.utf8.count) bytes · \(event)"
            // `load` runs inside updateNSView, where SwiftUI drops state
            // changes; publish on the next turn instead.
            DispatchQueue.main.async { [status] in status?.wrappedValue = text }
        }
    }
}
