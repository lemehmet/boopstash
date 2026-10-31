import CoreGraphics

/// The folding gutter's size for an editor font (#189): the chevron is
/// about the height of the font's capital letters, and the gutter is wide
/// enough for it with some padding, so both follow Settings ▸ Editor ▸ Size.
public struct FoldGutterMetrics: Equatable, Sendable {
    /// The narrowest gutter, as before #189, so small fonts keep a usable
    /// click target.
    public static let minimumWidth: CGFloat = 14

    /// The side of the square the chevron is fitted into, in points.
    public let chevronSide: CGFloat
    /// The gutter's width, in whole points.
    public let width: CGFloat

    /// `capHeight` is the editor font's cap height, in points.
    public init(capHeight: CGFloat) {
        let side = max(capHeight, 1)
        let padding = max(3, side / 4)
        chevronSide = side
        width = max(Self.minimumWidth, (side + 2 * padding).rounded(.up))
    }
}
