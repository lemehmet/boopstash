import AppKit
import BoopstashCore
import SwiftUI

/// What the shared preview (App/SharedViews) needs from the Mac: images,
/// colours and the editor's font.
typealias PlatformImage = NSImage

extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}

enum PreviewPlatform {
    static func color(_ color: ThemeColor) -> Color { Color(nsColor: NSColor(color)) }
    static var textBackground: Color { Color(nsColor: .textBackgroundColor) }
    static var text: Color { Color(nsColor: .textColor) }
    static var codeBackground: Color { Color(nsColor: .quaternaryLabelColor).opacity(0.5) }
    static func systemColor(for role: HighlightRole) -> Color { Color(nsColor: SyntaxTheme.systemColor(for: role)) }
    static func monospaced(_ appearance: EditorAppearance) -> Font { Font(EditorSettings.font(for: appearance)) }
}
