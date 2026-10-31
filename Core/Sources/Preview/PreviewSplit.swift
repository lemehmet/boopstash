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
    /// divider. Both panes keep the minimum width when there is room for
    /// it; when there is not, the space is split by the fraction alone.
    public static func leadingWidth(total: Double, fraction: Double, divider: Double) -> Double {
        let available = max(total - divider, 0)
        let wanted = available * clampedFraction(fraction)
        guard available >= 2 * minimumPaneWidth else { return wanted }
        return min(max(wanted, minimumPaneWidth), available - minimumPaneWidth)
    }

    /// The fraction to keep after the divider is dragged so that the editor
    /// would be `leadingWidth` wide: clamped as `leadingWidth(total:…)` would
    /// clamp it, so a drag past a pane's minimum stops at it.
    public static func fraction(leadingWidth: Double, total: Double, divider: Double) -> Double {
        let available = max(total - divider, 0)
        guard available > 0 else { return defaultFraction }
        let width = available >= 2 * minimumPaneWidth
            ? min(max(leadingWidth, minimumPaneWidth), available - minimumPaneWidth)
            : leadingWidth
        // Never all one pane: a divider dragged to the edge stays findable.
        return min(max(width / available, 0.05), 0.95)
    }

    /// A stored fraction that is not a share of anything (a hand-edited
    /// default, NaN) falls back to half each.
    public static func clampedFraction(_ fraction: Double) -> Double {
        fraction.isFinite && fraction > 0 && fraction < 1 ? fraction : defaultFraction
    }
}
