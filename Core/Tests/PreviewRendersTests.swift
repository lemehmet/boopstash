import Testing
@testable import BoopstashCore

@Suite struct PreviewRendersTests {
    @Test func nothingIsKeptBeforeARenderStarts() {
        #expect(!PreviewRenders().keeps("a"))
    }

    @Test func theNewestRenderIsKeptEvenIfItsTaskWasCancelled() {
        // The cancellation itself is not an input: a render of the newest
        // text shows however its task ended.
        var renders = PreviewRenders()
        renders.start("a")
        #expect(renders.keeps("a"))
    }

    @Test func aRenderOvertakenByNewerTextIsDropped() {
        var renders = PreviewRenders()
        renders.start("a")
        renders.start("ab")
        #expect(!renders.keeps("a"))
        #expect(renders.keeps("ab"))
    }

    @Test func goingBackToEarlierTextKeepsEitherRenderOfIt() {
        // Same text renders the same blocks, so an older render of it is fine.
        var renders = PreviewRenders()
        renders.start("a")
        renders.start("ab")
        renders.start("a")
        #expect(renders.keeps("a"))
        #expect(!renders.keeps("ab"))
    }
}
