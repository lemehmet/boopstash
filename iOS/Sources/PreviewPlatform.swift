import BoopstashCore
import SwiftUI
import UIKit

/// What the shared preview (App/SharedViews) needs from iOS: images,
/// colours (the editor's own) and a monospaced font.
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}

enum PreviewPlatform {
    static func color(_ color: ThemeColor) -> Color { Color(red: color.red, green: color.green, blue: color.blue) }
    static var textBackground: Color { Color(uiColor: .systemBackground) }
    static var text: Color { Color(uiColor: .label) }
    static var codeBackground: Color { Color(uiColor: .secondarySystemBackground) }
    static func systemColor(for role: HighlightRole) -> Color { Color(uiColor: PlainTextEditor.Painter.color(for: role)) }
    static func monospaced(_ appearance: EditorAppearance) -> Font { .system(size: CGFloat(appearance.fontSize), design: .monospaced) }
}
