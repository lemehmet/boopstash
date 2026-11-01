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

    @Test func aSplitWithNoRoomForTwoMinimumsIsHalfEach() {
        #expect(PreviewSplit.leadingWidth(total: 400, fraction: 0.25, divider: 0) == 200)
        #expect(PreviewSplit.leadingWidth(total: 0, fraction: 0.5, divider: 1) == 0)
    }

    @Test func theDividerMovesSmoothlyAsTheSplitNarrowsPastTwoMinimums() {
        // A share kept from a wide window, near either edge: at 480 both
        // panes are at their minimum, just under it they are still about half.
        for fraction in [0.24, 0.95] {
            #expect(PreviewSplit.leadingWidth(total: 480, fraction: fraction, divider: 0) == 240)
            #expect(PreviewSplit.leadingWidth(total: 478, fraction: fraction, divider: 0) == 239)
        }
    }

    @Test func aDragIsKeptAsAFractionAndStopsAtThePaneMinimums() {
        #expect(PreviewSplit.fraction(leadingWidth: 300, total: 1001, divider: 1) == 0.3)
        #expect(PreviewSplit.fraction(leadingWidth: 50, total: 1000, divider: 0) == 0.24)
        #expect(PreviewSplit.fraction(leadingWidth: 990, total: 1000, divider: 0) == 0.76)
    }

    @Test func aDragWhereTheDividerCannotMoveKeepsTheStoredShare() {
        #expect(PreviewSplit.fraction(leadingWidth: -20, total: 400, divider: 0) == nil)
        #expect(PreviewSplit.fraction(leadingWidth: 300, total: 480, divider: 0) == nil)
        #expect(PreviewSplit.fraction(leadingWidth: 10, total: 0, divider: 0) == nil)
    }

    @Test func onAVeryWideSplitADragStopsAtThePaneMinimumNotAShare() throws {
        // 240 of 6016 is under 5%; the drag still stops at 240 on both sides.
        let low = try #require(PreviewSplit.fraction(leadingWidth: 100, total: 6016, divider: 0))
        #expect(abs(PreviewSplit.leadingWidth(total: 6016, fraction: low, divider: 0) - 240) < 0.0001)
        let high = try #require(PreviewSplit.fraction(leadingWidth: 6000, total: 6016, divider: 0))
        #expect(abs(PreviewSplit.leadingWidth(total: 6016, fraction: high, divider: 0) - 5776) < 0.0001)
    }

    @Test func aDraggedFractionGivesBackTheSameWidth() throws {
        let fraction = try #require(PreviewSplit.fraction(leadingWidth: 612, total: 1400, divider: 1))
        #expect(abs(PreviewSplit.leadingWidth(total: 1400, fraction: fraction, divider: 1) - 612) < 0.0001)
    }

    @Test func anAdjustmentMovesTheDividerByAStepAndStopsWhereADragWould() {
        #expect(abs(PreviewSplit.adjusted(fraction: 0.5, by: 1, total: 1001, divider: 1) - 0.55) < 0.0001)
        #expect(abs(PreviewSplit.adjusted(fraction: 0.5, by: -1, total: 1001, divider: 1) - 0.45) < 0.0001)
        // 240 of 1000 is the editor's minimum; a further decrement stays there.
        #expect(PreviewSplit.adjusted(fraction: 0.24, by: -1, total: 1000, divider: 0) == 0.24)
        #expect(PreviewSplit.adjusted(fraction: 0.76, by: 1, total: 1000, divider: 0) == 0.76)
        // No room to move: the kept share stands.
        #expect(PreviewSplit.adjusted(fraction: 0.3, by: 1, total: 400, divider: 0) == 0.3)
        #expect(PreviewSplit.adjusted(fraction: 0.5, by: 1, total: 0, divider: 0) == 0.5)
        // No steps: a share that renders clamped (0.10 shows as 240 of 1000)
        // is kept, not replaced by the clamped one (#210).
        #expect(PreviewSplit.adjusted(fraction: 0.1, by: 0, total: 1000, divider: 0) == 0.1)
    }

    @Test func theEditorsShareIsReadAsTheWidthItActuallyHas() {
        #expect(PreviewSplit.editorPercent(total: 1001, fraction: 0.3, divider: 1) == 30)
        // 10% asked for, but the minimum width gives the editor 24%.
        #expect(PreviewSplit.editorPercent(total: 1000, fraction: 0.1, divider: 0) == 24)
        #expect(PreviewSplit.editorPercent(total: 0, fraction: 0.5, divider: 0) == 50)
    }

    @Test func aStoredFractionThatIsNoShareFallsBackToHalf() {
        for bad in [0, 1, -0.5, 3, .nan, .infinity] {
            #expect(PreviewSplit.clampedFraction(bad) == PreviewSplit.defaultFraction)
        }
        #expect(PreviewSplit.clampedFraction(0.7) == 0.7)
    }
}
