import BoopstashCore
import SwiftUI

/// The editor beside the preview, with a divider to drag (#207). Unlike
/// `HSplitView`, which starts over each time it is built, the editor's
/// share is kept in user defaults.
struct PreviewSplitView<Leading: View, Trailing: View>: View {
    @AppStorage(PreviewSettings.splitFractionKey) private var fraction = PreviewSplit.defaultFraction
    /// The editor's width when the drag began. Gesture state, so it is
    /// cleared however the drag ends, cancelled included.
    @GestureState private var dragStart: Double?
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
                                .updating($dragStart) { _, start, _ in
                                    if start == nil { start = width }
                                }
                                .onChanged { drag in
                                    fraction = PreviewSplit.fraction(leadingWidth: (dragStart ?? width) + drag.translation.width,
                                                                     total: total, divider: Self.dividerWidth)
                                })
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
                    // Above the preview, which comes later and would
                    // otherwise take the half of the grab area over it.
                    .zIndex(1)
                trailing.frame(maxWidth: .infinity)
            }
        }
    }
}
