import Testing
@testable import BoopstashCore

@MainActor @Suite struct PreviewRendersTests {
    @Test func aRenderShows() async {
        let renders = PreviewRenders()
        #expect(await renders.render("a") { $0 } == "a")
        #expect(renders.requested == "a")
    }

    @Test func aTaskCancelledBeforeItRunsStillRenders() async {
        let renders = PreviewRenders()
        let task = Task { await renders.render("a") { $0 } }
        task.cancel()
        #expect(await task.value == "a")
    }

    @Test func aTaskCancelledDuringTheDebounceRendersAtOnce() async {
        let renders = PreviewRenders()
        let task = Task { await renders.render("a", debounce: .seconds(60)) { $0 } }
        task.cancel()
        #expect(await task.value == "a")
    }

    @Test func newerTextDuringTheDebounceDropsTheRender() async {
        let renders = PreviewRenders()
        let older = Task { await renders.render("a", debounce: .seconds(60)) { $0 } }
        while renders.requested != "a" { await Task.yield() }
        #expect(await renders.render("ab") { $0 } == "ab")
        older.cancel()
        #expect(await older.value == nil)
    }

    @Test func aTaskCancelledForNewerTextDoesNotRenderItsOwn() async {
        // SwiftUI's order on new text: cancel the old task, then start the new.
        let renders = PreviewRenders()
        let rendered = Rendered()
        let older = Task { await renders.render("a", debounce: .seconds(60)) { await rendered.add($0) } }
        while renders.requested != "a" { await Task.yield() }
        older.cancel()
        let newer = Task { await renders.render("ab") { await rendered.add($0) } }
        #expect(await older.value == nil)
        #expect(await newer.value == "ab")
        #expect(await rendered.texts == ["ab"])
    }

    @Test func newerTextDuringTheRenderDropsIt() async {
        let renders = PreviewRenders()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let older = Task {
            await renders.render("a") { text in
                for await _ in gate { break }
                return text
            }
        }
        while renders.requested != "a" { await Task.yield() }
        #expect(await renders.render("ab") { $0 } == "ab")
        open.finish()
        #expect(await older.value == nil)
    }
}

/// The texts a test's renders were run for.
private actor Rendered {
    var texts: [String] = []

    func add(_ text: String) -> String {
        texts.append(text)
        return text
    }
}
