import Foundation
import Testing
@testable import BoopstashCore

/// The folding gutter follows the editor font (#189).
@Suite struct FoldGutterMetricsTests {
    /// Cap heights of the system monospaced font are about 0.7 of its size.
    static let sizes: [CGFloat] = [9, 13, 24, 36]

    @Test(arguments: sizes) func chevronIsTheCapHeightAndFitsWithPadding(size: CGFloat) {
        let capHeight = size * 0.7
        let metrics = FoldGutterMetrics(capHeight: capHeight)
        #expect(metrics.chevronSide == capHeight)
        // Never clipped: at least 3 pt either side.
        #expect(metrics.width >= metrics.chevronSide + 6)
        #expect(metrics.width >= FoldGutterMetrics.minimumWidth)
        #expect(metrics.width == metrics.width.rounded())
    }

    @Test func growsWithTheFont() {
        let widths = Self.sizes.map { FoldGutterMetrics(capHeight: $0 * 0.7).width }
        #expect(widths == widths.sorted())
        #expect(widths.first == FoldGutterMetrics.minimumWidth)
        #expect(widths.last! > 30)
        // A 24 pt chevron is far larger than the old fixed 10 pt triangle.
        #expect(FoldGutterMetrics(capHeight: 24 * 0.7).chevronSide > 15)
    }

    @Test func degenerateCapHeightStillGivesAGutter() {
        let metrics = FoldGutterMetrics(capHeight: 0)
        #expect(metrics.chevronSide == 1)
        #expect(metrics.width == FoldGutterMetrics.minimumWidth)
    }
}
