import Foundation

/// View ▸ Show Preview and its layout, remembered across launches.
enum PreviewSettings {
    static let shownKey = "previewShown"
    static let sideBySideKey = "previewSideBySide"
    /// The editor's share beside the preview (#207).
    static let splitFractionKey = "previewSplitFraction"
}
