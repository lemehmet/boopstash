import Foundation

/// The editor and the preview side by side (#207): the editor's share of
/// the width is kept, so switching notes, toggling the preview and
/// relaunching leave the divider where it was dragged.
public enum PreviewSplit {
    /// Half each, until the divider is dragged.
    public static let defaultFraction = 0.5
    /// Neither pane is squeezed narrower than this while both fit.
    public static let minimumPaneWidth = 240.0

    /// The editor's width for `fraction` of the space left beside the
    /// divider. Neither pane is narrower than the minimum; when there is no
    /// room for two minimums the panes take half each, so the divider moves
    /// smoothly as the split narrows past the point where they meet.
    public static func leadingWidth(total: Double, fraction: Double, divider: Double) -> Double {
        let available = max(total - divider, 0)
        let minimum = min(minimumPaneWidth, available / 2)
        return min(max(available * clampedFraction(fraction), minimum), available - minimum)
    }

    /// The fraction to keep after the divider is dragged so that the editor
    /// would be `leadingWidth` wide, clamped as `leadingWidth(total:…)`
    /// clamps it so a drag past a pane's minimum stops at it. `nil` when the
    /// split is too narrow for the divider to move: the kept share stands.
    public static func fraction(leadingWidth: Double, total: Double, divider: Double) -> Double? {
        let available = max(total - divider, 0)
        guard available > 2 * minimumPaneWidth else { return nil }
        return min(max(leadingWidth, minimumPaneWidth), available - minimumPaneWidth) / available
    }

    /// The fraction to keep while the divider is dragged by `translation`
    /// from where the stored `startFraction` put it (`startWidth`). A drag
    /// that is back where it began, or that a pane's minimum holds there,
    /// keeps the stored share, also one that renders clamped: a 0.10 share
    /// showing as 240 of 1000 is not replaced by 0.24 (#226). `nil` when the
    /// split is too narrow for the divider to move.
    public static func dragged(from startFraction: Double, startWidth: Double, by translation: Double,
                               total: Double, divider: Double) -> Double? {
        guard let next = fraction(leadingWidth: startWidth + translation, total: total, divider: divider) else { return nil }
        let width = leadingWidth(total: total, fraction: next, divider: divider)
        return abs(width - startWidth) < 0.000_001 ? startFraction : next
    }

    /// How far one VoiceOver increment or decrement moves the divider: this
    /// share of the space beside it.
    public static let adjustmentStep = 0.05

    /// The fraction after `steps` assistive-tech adjustments (positive widens
    /// the editor), clamped exactly as a drag is; unchanged where a drag
    /// could not move the divider either. No steps keep the share as it is,
    /// also when it renders clamped at a pane's minimum (#210), and so does
    /// a step toward the minimum it is already held at (#226).
    public static func adjusted(fraction: Double, by steps: Int, total: Double, divider: Double) -> Double {
        guard steps != 0 else { return fraction }
        let available = max(total - divider, 0)
        let width = leadingWidth(total: total, fraction: fraction, divider: divider)
        return dragged(from: fraction, startWidth: width, by: Double(steps) * adjustmentStep * available,
                       total: total, divider: divider) ?? fraction
    }

    /// The editor's share of the space beside the divider as a whole
    /// percentage, for VoiceOver to read out.
    public static func editorPercent(total: Double, fraction: Double, divider: Double) -> Int {
        let available = max(total - divider, 0)
        guard available > 0 else { return 50 }
        return Int((leadingWidth(total: total, fraction: fraction, divider: divider) / available * 100).rounded())
    }

    /// A stored fraction that is not a share of anything (a hand-edited
    /// default, NaN) falls back to half each.
    public static func clampedFraction(_ fraction: Double) -> Double {
        fraction.isFinite && fraction > 0 && fraction < 1 ? fraction : defaultFraction
    }
}
