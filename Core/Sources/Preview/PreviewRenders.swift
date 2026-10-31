/// Which finished preview render may show (#206). A render that completes is
/// kept even if its task was cancelled, unless newer text was asked for
/// since: on iOS, opening a second note can cancel the render of a preview
/// that stays on screen and is never asked to render again.
public struct PreviewRenders: Equatable, Sendable {
    /// The text the newest render was started for.
    public private(set) var requested: String?

    public init() {}

    /// A render was started for `markdown`.
    public mutating func start(_ markdown: String) {
        requested = markdown
    }

    /// Whether a finished render of `markdown` should replace what shows.
    public func keeps(_ markdown: String) -> Bool {
        requested == markdown
    }
}
