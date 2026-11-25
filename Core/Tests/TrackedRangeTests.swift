import Foundation
import Testing
@testable import BoopstashCore

@Suite struct TrackedRangeTests {
    let range = NSRange(location: 10, length: 5)

    @Test func anInsertionBeforeShiftsTheRange() {
        #expect(TrackedRange.adjusted(range, editedRange: NSRange(location: 2, length: 3), delta: 3) == NSRange(location: 13, length: 5))
        #expect(TrackedRange.adjusted(range, editedRange: NSRange(location: 10, length: 4), delta: 4) == NSRange(location: 14, length: 5),
                "text put right before it")
    }

    @Test func aDeletionBeforeShiftsTheRangeBack() {
        #expect(TrackedRange.adjusted(range, editedRange: NSRange(location: 4, length: 0), delta: -6) == NSRange(location: 4, length: 5))
    }

    @Test func anEditAfterLeavesTheRange() {
        #expect(TrackedRange.adjusted(range, editedRange: NSRange(location: 15, length: 2), delta: 2) == range)
        #expect(TrackedRange.adjusted(range, editedRange: NSRange(location: 40, length: 0), delta: -3) == range)
    }

    @Test func anEditThatTouchesTheRangeLosesIt() {
        #expect(TrackedRange.adjusted(range, editedRange: NSRange(location: 12, length: 1), delta: 1) == nil, "typed inside")
        #expect(TrackedRange.adjusted(range, editedRange: NSRange(location: 8, length: 0), delta: -4) == nil, "deleted across its start")
        #expect(TrackedRange.adjusted(range, editedRange: NSRange(location: 10, length: 0), delta: -5) == nil, "deleted whole")
        #expect(TrackedRange.adjusted(range, editedRange: NSRange(location: 0, length: 3), delta: -30) == nil, "replaced with the text around it")
    }

    @Test func aChangeOfAttributesOnlyLeavesTheRange() {
        #expect(TrackedRange.adjusted(range, editedRange: NSRange(location: 0, length: 0), delta: 0) == range)
    }

    @Test func aReloadedTextIsSearchedForTheOnePlace() {
        let one = [NSRange(location: 7, length: 5)]
        let two = [NSRange(location: 0, length: 5), NSRange(location: 9, length: 5)]
        #expect(TrackedRange.reloaded(before: 1, among: one) == .found(NSRange(location: 7, length: 5)))
        #expect(TrackedRange.reloaded(before: 1, among: []) == .gone)
        #expect(TrackedRange.reloaded(before: 2, among: []) == .gone)
        #expect(TrackedRange.reloaded(before: 1, among: two) == .ambiguous, "which of two it is cannot be told")
        #expect(TrackedRange.reloaded(before: 2, among: one) == .ambiguous, "the one left may be the other of the two")
        #expect(TrackedRange.reloaded(before: 2, among: two) == .ambiguous)
    }
}
