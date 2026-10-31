/// The preview's renders (#206). A render shows unless newer text was asked
/// for since, however its task ended: on iOS, opening a second note can
/// cancel the task of a preview that stays on screen and is never asked to
/// render again, so cancellation alone must not drop it.
@MainActor
public final class PreviewRenders {
    /// The text the newest render was asked for.
    public private(set) var requested: String?

    public init() {}

    /// Renders `markdown` after `debounce`, or nil when newer text was asked
    /// for before it finished. A cancelled debounce ends early and renders.
    public func render<Output: Sendable>(
        _ markdown: String,
        debounce: Duration? = nil,
        _ render: @Sendable (String) async -> Output
    ) async -> Output? {
        requested = markdown
        if let debounce { try? await Task.sleep(for: debounce) }
        // Cancelled for newer text, this task can resume before its
        // replacement records that text; let the replacement go first so
        // typing does not render every superseded keystroke.
        if Task.isCancelled { await Task.yield() }
        guard requested == markdown else { return nil }
        let output = await render(markdown)
        return requested == markdown ? output : nil
    }
}
