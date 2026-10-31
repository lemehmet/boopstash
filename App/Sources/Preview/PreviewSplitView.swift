import BoopstashCore
import SwiftUI

/// The editor beside the preview, with a divider to drag (#207). Unlike
/// `HSplitView`, which starts over each time it is built, the editor's
/// share is kept in user defaults.
struct PreviewSplitView<Leading: View, Trailing: View>: View {
    @AppStorage(PreviewSettings.splitFractionKey) private var fraction = PreviewSplit.defaultFraction
    /// The editor's width while the divider is being dragged.
    @State private var dragStart: Double?
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    private static var dividerWidth: Double { 1 }
    /// Wider than the line, so the divider is easy to grab.
    private static var grabWidth: Double { 9 }

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let width = PreviewSplit.leadingWidth(total: total, fraction: fraction, divider: Self.dividerWidth)
            HStack(spacing: 0) {
                leading.frame(width: width)
                Divider()
                    .overlay {
                        Color.clear
                            .frame(width: Self.grabWidth)
                            .contentShape(Rectangle())
                            .pointerStyle(.columnResize)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { drag in
                                    let start = dragStart ?? width
                                    dragStart = start
                                    fraction = PreviewSplit.fraction(leadingWidth: start + drag.translation.width,
                                                                     total: total, divider: Self.dividerWidth)
                                }
                                .onEnded { _ in dragStart = nil })
                            // HSplitView's divider was adjustable from
                            // VoiceOver; this one is too.
                            .accessibilityElement()
                            .accessibilityLabel("Editor and preview divider")
                            .accessibilityValue("Editor \(PreviewSplit.editorPercent(total: total, fraction: fraction, divider: Self.dividerWidth)) percent")
                            .accessibilityAdjustableAction { direction in
                                let steps = switch direction {
                                case .increment: 1
                                case .decrement: -1
                                @unknown default: 0
                                }
                                fraction = PreviewSplit.adjusted(fraction: fraction, by: steps,
                                                                 total: total, divider: Self.dividerWidth)
                            }
                    }
                trailing.frame(maxWidth: .infinity)
            }
        }
    }
}
