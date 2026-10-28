import Foundation

/// What a highlighted range is, for colouring: tree-sitter's many capture
/// names ("keyword.function", "string.special.url", "text.title") collapse
/// into these.
public enum HighlightRole: String, CaseIterable, Sendable {
    case comment, string, escape, number, keyword, function, type, property, builtin
    case heading, link, added, removed, changed

    /// The role for a tree-sitter capture name, or nil for captures drawn in
    /// the text colour (punctuation, plain variables).
    public static func role(for capture: String) -> HighlightRole? {
        let parts = capture.split(separator: ".")
        switch parts.first {
        case "comment": return .comment
        case "string":
            return parts.contains("escape") || parts.contains("regex") ? .escape : .string
        case "character", "escape": return .escape
        case "number", "float", "boolean", "constant": return .number
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass", "preproc", "define":
            return .keyword
        case "function", "method", "constructor": return .function
        case "type", "namespace", "module": return .type
        case "property", "field", "attribute", "label", "tag": return .property
        case "variable": return parts.contains("builtin") ? .builtin : nil
        case "text", "markup":
            if parts.contains("title") || parts.contains("heading") { return .heading }
            if parts.contains("literal") || parts.contains("raw") { return .string }
            if parts.contains("uri") || parts.contains("link") { return .link }
            return nil
        case "diff":
            if parts.contains("plus") { return .added }
            if parts.contains("minus") { return .removed }
            return .changed
        default: return nil
        }
    }
}

/// An sRGB colour from a theme's published hex value.
public struct ThemeColor: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    /// `#rrggbb`; a malformed value is a programming error in the theme
    /// table, caught by the tests.
    public init(_ hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio against another colour (1 to 21).
    public func contrast(with other: ThemeColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// An editor colour scheme: background, text, caret, selection and a colour
/// per highlight role. The built-in themes are well-known open schemes; only
/// their published colour values are used (see THIRD_PARTY_NOTICES.md).
public struct Theme: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let background: ThemeColor
    public let foreground: ThemeColor
    public let caret: ThemeColor
    public let selection: ThemeColor
    public let roles: [HighlightRole: ThemeColor]

    public func color(for role: HighlightRole) -> ThemeColor {
        roles[role] ?? foreground
    }

    /// The id for "use the system's colours", which is not a palette: the
    /// app draws it with semantic system colours that follow the appearance.
    public static let systemID = "system"

    public static func named(_ id: String) -> Theme? {
        all.first { $0.id == id }
    }

    init(_ id: String, _ name: String, dark: Bool, background: String, foreground: String, caret: String, selection: String,
         _ roles: [HighlightRole: String]) {
        self.id = id
        self.name = name
        isDark = dark
        self.background = ThemeColor(background)
        self.foreground = ThemeColor(foreground)
        self.caret = ThemeColor(caret)
        self.selection = ThemeColor(selection)
        self.roles = roles.mapValues(ThemeColor.init)
    }

    // Role assignments follow each scheme's own editor ports where they
    // agree; diffs use the scheme's green, red and blue.
    public static let all: [Theme] = [
        Theme("solarized-light", "Solarized Light", dark: false,
              background: "#fdf6e3", foreground: "#657b83", caret: "#586e75", selection: "#eee8d5", [
                .comment: "#93a1a1", .string: "#2aa198", .escape: "#cb4b16", .number: "#d33682",
                .keyword: "#859900", .function: "#268bd2", .type: "#b58900", .property: "#268bd2",
                .builtin: "#cb4b16", .heading: "#268bd2", .link: "#6c71c4",
                .added: "#859900", .removed: "#dc322f", .changed: "#268bd2",
              ]),
        Theme("solarized-dark", "Solarized Dark", dark: true,
              background: "#002b36", foreground: "#839496", caret: "#93a1a1", selection: "#073642", [
                .comment: "#586e75", .string: "#2aa198", .escape: "#cb4b16", .number: "#d33682",
                .keyword: "#859900", .function: "#268bd2", .type: "#b58900", .property: "#268bd2",
                .builtin: "#cb4b16", .heading: "#268bd2", .link: "#6c71c4",
                .added: "#859900", .removed: "#dc322f", .changed: "#268bd2",
              ]),
        Theme("github-light", "GitHub Light", dark: false,
              background: "#ffffff", foreground: "#1f2328", caret: "#1f2328", selection: "#b6e3ff", [
                .comment: "#59636e", .string: "#0a3069", .escape: "#0550ae", .number: "#0550ae",
                .keyword: "#cf222e", .function: "#8250df", .type: "#953800", .property: "#0550ae",
                .builtin: "#953800", .heading: "#0550ae", .link: "#0969da",
                .added: "#116329", .removed: "#82071e", .changed: "#953800",
              ]),
        Theme("github-dark", "GitHub Dark", dark: true,
              background: "#0d1117", foreground: "#e6edf3", caret: "#e6edf3", selection: "#264f78", [
                .comment: "#9198a1", .string: "#a5d6ff", .escape: "#79c0ff", .number: "#79c0ff",
                .keyword: "#ff7b72", .function: "#d2a8ff", .type: "#ffa657", .property: "#79c0ff",
                .builtin: "#ffa657", .heading: "#79c0ff", .link: "#4493f8",
                .added: "#7ee787", .removed: "#ffa198", .changed: "#ffa657",
              ]),
        Theme("one-light", "One Light", dark: false,
              background: "#fafafa", foreground: "#383a42", caret: "#526fff", selection: "#e5e5e6", [
                .comment: "#a0a1a7", .string: "#50a14f", .escape: "#0184bc", .number: "#986801",
                .keyword: "#a626a4", .function: "#4078f2", .type: "#c18401", .property: "#e45649",
                .builtin: "#0184bc", .heading: "#e45649", .link: "#4078f2",
                .added: "#50a14f", .removed: "#e45649", .changed: "#986801",
              ]),
        Theme("one-dark", "One Dark", dark: true,
              background: "#282c34", foreground: "#abb2bf", caret: "#528bff", selection: "#3e4451", [
                .comment: "#7f848e", .string: "#98c379", .escape: "#56b6c2", .number: "#d19a66",
                .keyword: "#c678dd", .function: "#61afef", .type: "#e5c07b", .property: "#e06c75",
                .builtin: "#56b6c2", .heading: "#e06c75", .link: "#61afef",
                .added: "#98c379", .removed: "#e06c75", .changed: "#d19a66",
              ]),
        Theme("gruvbox-light", "Gruvbox Light", dark: false,
              background: "#fbf1c7", foreground: "#3c3836", caret: "#3c3836", selection: "#d5c4a1", [
                .comment: "#7c6f64", .string: "#79740e", .escape: "#af3a03", .number: "#8f3f71",
                .keyword: "#9d0006", .function: "#427b58", .type: "#b57614", .property: "#076678",
                .builtin: "#af3a03", .heading: "#076678", .link: "#076678",
                .added: "#79740e", .removed: "#9d0006", .changed: "#b57614",
              ]),
        Theme("gruvbox-dark", "Gruvbox Dark", dark: true,
              background: "#282828", foreground: "#ebdbb2", caret: "#ebdbb2", selection: "#504945", [
                .comment: "#928374", .string: "#b8bb26", .escape: "#fe8019", .number: "#d3869b",
                .keyword: "#fb4934", .function: "#8ec07c", .type: "#fabd2f", .property: "#83a598",
                .builtin: "#fe8019", .heading: "#83a598", .link: "#83a598",
                .added: "#b8bb26", .removed: "#fb4934", .changed: "#fabd2f",
              ]),
        Theme("dracula", "Dracula", dark: true,
              background: "#282a36", foreground: "#f8f8f2", caret: "#f8f8f2", selection: "#44475a", [
                .comment: "#6272a4", .string: "#f1fa8c", .escape: "#ff79c6", .number: "#bd93f9",
                .keyword: "#ff79c6", .function: "#50fa7b", .type: "#8be9fd", .property: "#66d9ef",
                .builtin: "#bd93f9", .heading: "#bd93f9", .link: "#8be9fd",
                .added: "#50fa7b", .removed: "#ff5555", .changed: "#ffb86c",
              ]),
        Theme("nord", "Nord", dark: true,
              background: "#2e3440", foreground: "#d8dee9", caret: "#d8dee9", selection: "#434c5e", [
                .comment: "#7b88a1", .string: "#a3be8c", .escape: "#ebcb8b", .number: "#b48ead",
                .keyword: "#81a1c1", .function: "#88c0d0", .type: "#8fbcbb", .property: "#88c0d0",
                .builtin: "#81a1c1", .heading: "#88c0d0", .link: "#88c0d0",
                .added: "#a3be8c", .removed: "#bf616a", .changed: "#ebcb8b",
              ]),
    ]
}

/// The editor's font and themes as the user set them. "System" is a theme
/// id meaning the system's own colours.
public struct EditorAppearance: Hashable, Sendable {
    /// A monospaced font family; empty means the system monospaced font.
    public var fontFamily: String
    public var fontSize: Double
    public var lightThemeID: String
    public var darkThemeID: String

    public static let fontSizes: ClosedRange<Double> = 9...36

    public init(fontFamily: String = "", fontSize: Double = 13, lightThemeID: String = Theme.systemID, darkThemeID: String = Theme.systemID) {
        self.fontFamily = fontFamily
        self.fontSize = min(max(fontSize, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        self.lightThemeID = lightThemeID
        self.darkThemeID = darkThemeID
    }

    /// The theme for the current appearance, or nil for the system colours
    /// (also when a stored id names a theme that no longer exists).
    public func theme(dark: Bool) -> Theme? {
        Theme.named(dark ? darkThemeID : lightThemeID)
    }
}
