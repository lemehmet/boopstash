import Foundation
import Testing
@testable import BoopstashCore

/// Where the workbench's window opens and how it is divided (#285).
@Suite struct ScriptWorkbenchLayoutTests {
    static let laptop = CGRect(x: 0, y: 0, width: 1440, height: 870)
    /// A second display to the right, set higher.
    static let external = CGRect(x: 1440, y: 200, width: 2560, height: 1400)
    let minimum = ScriptWorkbenchLayout.minimumSize

    // MARK: The title

    @Test func theTitleNamesTheNote() {
        #expect(ScriptWorkbenchLayout.windowTitle(note: "Tickets") == "Script Workbench — Tickets")
        #expect(ScriptWorkbenchLayout.windowTitle(note: "  ") == "Script Workbench")
        #expect(ScriptWorkbenchLayout.windowTitle(note: "") == "Script Workbench")
        #expect(ScriptWorkbenchLayout.windowTitle(note: "two\nlines ") == "Script Workbench — two lines")
        let long = String(repeating: "word ", count: 40)
        let title = ScriptWorkbenchLayout.windowTitle(note: long)
        #expect(title.hasSuffix("…") && title.count <= "Script Workbench — ".count + 61)
        #expect(!title.hasSuffix(" …"), "no space before the ellipsis")
    }

    // MARK: The frame

    @Test func aFrameIsStoredAndReadBack() {
        let frame = CGRect(x: -300.5, y: 40, width: 1800, height: 1200)
        #expect(ScriptWorkbenchLayout.frame(stored: ScriptWorkbenchLayout.stored(frame)) == frame)
        #expect(ScriptWorkbenchLayout.frame(stored: nil) == nil)
        #expect(ScriptWorkbenchLayout.frame(stored: []) == nil)
        #expect(ScriptWorkbenchLayout.frame(stored: [0, 0, 100]) == nil)
        #expect(ScriptWorkbenchLayout.frame(stored: [0, 0, 100, 100, 5]) == nil)
        #expect(ScriptWorkbenchLayout.frame(stored: [0, 0, 0, 100]) == nil, "an empty size is not a frame")
        #expect(ScriptWorkbenchLayout.frame(stored: [0, 0, 100, -4]) == nil)
        #expect(ScriptWorkbenchLayout.frame(stored: [.nan, 0, 100, 100]) == nil)
        #expect(ScriptWorkbenchLayout.frame(stored: [0, .infinity, 100, 100]) == nil)
        #expect(ScriptWorkbenchLayout.frame(stored: [0, 0, 1e12, 100]) == nil)
    }

    @Test func withNothingRememberedItOpensAtTheDefaultSizeInTheMiddleOfTheNotesScreen() {
        let size = ScriptWorkbenchLayout.defaultSize
        let frame = ScriptWorkbenchLayout.frame(remembered: nil, screens: [Self.laptop, Self.external], home: Self.external)
        #expect(frame.size == size)
        #expect(frame.midX == Self.external.midX && frame.midY == Self.external.midY)
        // Without a home screen, the first one.
        let first = ScriptWorkbenchLayout.frame(remembered: nil, screens: [Self.laptop, Self.external], home: nil)
        #expect(first.midX == Self.laptop.midX && first.size == size)
        // With no screen at all there is still a frame.
        #expect(ScriptWorkbenchLayout.frame(remembered: nil, screens: [], home: nil).size == size)
    }

    @Test func theDefaultSizeIsCutToASmallScreenButNotUnderTheMinimum() {
        let small = CGRect(x: 0, y: 0, width: 900, height: 500)
        let frame = ScriptWorkbenchLayout.frame(remembered: nil, screens: [small], home: small)
        #expect(frame == CGRect(x: 0, y: 0, width: 900, height: 500))
        let tiny = CGRect(x: 10, y: 20, width: 600, height: 300)
        let cramped = ScriptWorkbenchLayout.frame(remembered: nil, screens: [tiny], home: tiny)
        #expect(cramped.size == minimum)
        #expect(cramped.minX == tiny.minX && cramped.maxY == tiny.maxY, "its top left corner, and so its title bar, is on the screen")
    }

    @Test func aRememberedFrameIsUsedAsItWasEvenLargerThanTheNotesWindowAndOnAnotherDisplay() {
        let remembered = CGRect(x: 1500, y: 300, width: 2400, height: 1250)
        #expect(ScriptWorkbenchLayout.frame(remembered: remembered, screens: [Self.laptop, Self.external], home: Self.laptop) == remembered)
        // Partly off the screen is the user's choice, as long as the title bar can be reached.
        let hanging = CGRect(x: -700, y: -400, width: 1000, height: 620)
        #expect(ScriptWorkbenchLayout.frame(remembered: hanging, screens: [Self.laptop], home: Self.laptop) == hanging)
        // Across two displays.
        let across = CGRect(x: 1000, y: 250, width: 1600, height: 600)
        #expect(ScriptWorkbenchLayout.frame(remembered: across, screens: [Self.laptop, Self.external], home: Self.laptop) == across)
    }

    @Test func aRememberedFrameOnADisplayThatIsGoneComesBackToTheNotesScreen() {
        let remembered = CGRect(x: 1500, y: 300, width: 2400, height: 1250)
        let frame = ScriptWorkbenchLayout.frame(remembered: remembered, screens: [Self.laptop], home: Self.laptop)
        #expect(Self.laptop.contains(frame), "\(frame)")
        #expect(frame.size == CGSize(width: 1440, height: 870), "cut to the screen")
        // One that fits keeps its size and moves the least.
        let fits = CGRect(x: 3000, y: 900, width: 1000, height: 620)
        let moved = ScriptWorkbenchLayout.frame(remembered: fits, screens: [Self.laptop], home: Self.laptop)
        #expect(moved.size == fits.size && Self.laptop.contains(moved))
        #expect(moved.maxX == Self.laptop.maxX && moved.maxY == Self.laptop.maxY)
    }

    @Test func aRememberedFrameWhoseTitleBarIsOutOfReachIsBroughtBack() {
        // Only a sliver of the title bar shows.
        let sliver = CGRect(x: 1440 - 40, y: 100, width: 1000, height: 620)
        let frame = ScriptWorkbenchLayout.frame(remembered: sliver, screens: [Self.laptop], home: Self.laptop)
        #expect(Self.laptop.contains(frame) && frame.size == sliver.size)
        // The title bar is above the screen though the rest shows.
        let above = CGRect(x: 100, y: 400, width: 1000, height: 620)
        let lowered = ScriptWorkbenchLayout.frame(remembered: above, screens: [Self.laptop], home: Self.laptop)
        #expect(lowered.maxY == Self.laptop.maxY && lowered.minX == 100)
        // With no screen to bring it to, it is left alone.
        #expect(ScriptWorkbenchLayout.frame(remembered: sliver, screens: [], home: nil) == sliver)
    }

    @Test func aRememberedFrameUnderTheMinimumGrowsFromItsTopLeftCorner() {
        let small = CGRect(x: 200, y: 500, width: 300, height: 200)
        let frame = ScriptWorkbenchLayout.frame(remembered: small, screens: [Self.laptop], home: Self.laptop)
        #expect(frame.size == minimum)
        #expect(frame.minX == small.minX && frame.maxY == small.maxY)
    }

    // MARK: The split

    @Test func aStoredSplitIsAShareOrTheDefault() {
        #expect(ScriptWorkbenchLayout.split(stored: nil) == ScriptWorkbenchLayout.defaultSplit)
        #expect(ScriptWorkbenchLayout.split(stored: 0.3) == 0.3)
        for bad in [0, 1, -0.2, 1.5, Double.nan, .infinity] {
            #expect(ScriptWorkbenchLayout.split(stored: bad) == ScriptWorkbenchLayout.defaultSplit, "\(bad)")
        }
    }

    @Test func theScriptPaneTakesItsShareWithBothPanesAtLeastTheMinimum() {
        #expect(ScriptWorkbenchLayout.scriptWidth(split: 0.5, total: 1000) == 500)
        #expect(ScriptWorkbenchLayout.scriptWidth(split: 0.3, total: 2000) == 600)
        #expect(ScriptWorkbenchLayout.scriptWidth(split: 0.1, total: 1000) == 320, "not under the minimum")
        #expect(ScriptWorkbenchLayout.scriptWidth(split: 0.9, total: 1000) == 680, "nor leaving the diff under it")
        #expect(ScriptWorkbenchLayout.scriptWidth(split: 0.9, total: 500) == 250, "no room for two minimums: half each")
        #expect(ScriptWorkbenchLayout.scriptWidth(split: 0.5, total: 0) == 0)
        #expect(ScriptWorkbenchLayout.scriptWidth(split: .nan, total: 1000) == 460, "a bad share is the default one")
    }

    @Test func aDraggedDividerIsAShareOfTheWidthThatLeavesBothPanesTheirMinimum() {
        #expect(ScriptWorkbenchLayout.split(draggedTo: 400, total: 1000) == 0.4)
        #expect(ScriptWorkbenchLayout.split(draggedTo: -50, total: 1000) == 0.32, "dragged past the edge, it stops at the minimum")
        #expect(ScriptWorkbenchLayout.split(draggedTo: 5000, total: 1000) == 0.68)
        #expect(ScriptWorkbenchLayout.split(draggedTo: 300, total: 500) == nil, "no room to choose in")
        #expect(ScriptWorkbenchLayout.split(draggedTo: 10, total: 0) == nil)
        #expect(ScriptWorkbenchLayout.split(draggedTo: .nan, total: 1000) == nil)
        // A share stored and applied to another width gives that share of it.
        let share = ScriptWorkbenchLayout.split(draggedTo: 700, total: 1400)
        #expect(share == 0.5)
        #expect(ScriptWorkbenchLayout.scriptWidth(split: ScriptWorkbenchLayout.split(stored: share), total: 2000) == 1000)
    }

    @Test func theShareShownIsTheOneOnScreenWhenTheWindowIsNarrowerThanTheShareWasSetIn() {
        #expect(ScriptWorkbenchLayout.shownSplit(split: 0.5, total: 1000) == 0.5)
        // 0.8 set in a wide window; at 800 the script is held to 480.
        #expect(ScriptWorkbenchLayout.shownSplit(split: 0.8, total: 800) == 0.6)
        #expect(ScriptWorkbenchLayout.shownSplit(split: 0.1, total: 800) == 0.4)
        #expect(ScriptWorkbenchLayout.shownSplit(split: 0.9, total: 500) == 0.5, "no room for two minimums: half each")
        #expect(ScriptWorkbenchLayout.shownSplit(split: 0.3, total: 0) == 0.3, "nothing shown: the share as stored")
        #expect(ScriptWorkbenchLayout.shownSplit(split: .nan, total: 0) == ScriptWorkbenchLayout.defaultSplit)
    }

    @Test func aStepOfTheDividerIsFromWhereItIsShown() {
        #expect(ScriptWorkbenchLayout.scriptWidth(split: 0.5, steppedBy: 0.05, total: 1000) == 550)
        #expect(ScriptWorkbenchLayout.scriptWidth(split: 0.5, steppedBy: -0.05, total: 1000) == 450)
        // Shown at 480 of 800, though 0.8 is stored: one step down is 440, not 600.
        let down = ScriptWorkbenchLayout.scriptWidth(split: 0.8, steppedBy: -0.05, total: 800)
        #expect(down == 440)
        #expect(ScriptWorkbenchLayout.split(draggedTo: down, total: 800) == 0.55)
        // A step up from the most the script can have stays there.
        let up = ScriptWorkbenchLayout.scriptWidth(split: 0.8, steppedBy: 0.05, total: 800)
        #expect(ScriptWorkbenchLayout.split(draggedTo: up, total: 800) == 0.6)
    }
}
