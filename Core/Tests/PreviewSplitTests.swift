import Testing
@testable import BoopstashCore

@Suite struct PreviewSplitTests {
    @Test func theFractionSharesTheSpaceBesideTheDivider() {
        #expect(PreviewSplit.leadingWidth(total: 1001, fraction: 0.5, divider: 1) == 500)
        #expect(PreviewSplit.leadingWidth(total: 1001, fraction: 0.3, divider: 1) == 300)
    }

    @Test func bothPanesKeepTheirMinimumWhenThereIsRoom() {
        // 10% of 1000 would leave the editor 100 wide.
        #expect(PreviewSplit.leadingWidth(total: 1000, fraction: 0.1, divider: 0) == 240)
        #expect(PreviewSplit.leadingWidth(total: 1000, fraction: 0.95, divider: 0) == 760)
    }

    @Test func aNarrowWindowSplitsByTheFractionAlone() {
        #expect(PreviewSplit.leadingWidth(total: 400, fraction: 0.25, divider: 0) == 100)
        #expect(PreviewSplit.leadingWidth(total: 0, fraction: 0.5, divider: 1) == 0)
    }

    @Test func aDragIsKeptAsAFractionAndStopsShortOfTheEdges() {
        #expect(PreviewSplit.fraction(leadingWidth: 300, total: 1001, divider: 1) == 0.3)
        #expect(PreviewSplit.fraction(leadingWidth: 50, total: 1000, divider: 0) == 0.24)
        #expect(PreviewSplit.fraction(leadingWidth: 990, total: 1000, divider: 0) == 0.76)
        #expect(PreviewSplit.fraction(leadingWidth: -20, total: 400, divider: 0) == 0.05)
        #expect(PreviewSplit.fraction(leadingWidth: 420, total: 400, divider: 0) == 0.95)
        #expect(PreviewSplit.fraction(leadingWidth: 10, total: 0, divider: 0) == PreviewSplit.defaultFraction)
    }

    @Test func aDraggedFractionGivesBackTheSameWidth() {
        let fraction = PreviewSplit.fraction(leadingWidth: 612, total: 1400, divider: 1)
        #expect(abs(PreviewSplit.leadingWidth(total: 1400, fraction: fraction, divider: 1) - 612) < 0.0001)
    }

    @Test func aStoredFractionThatIsNoShareFallsBackToHalf() {
        for bad in [0, 1, -0.5, 3, .nan, .infinity] {
            #expect(PreviewSplit.clampedFraction(bad) == PreviewSplit.defaultFraction)
        }
        #expect(PreviewSplit.clampedFraction(0.7) == 0.7)
    }
}
