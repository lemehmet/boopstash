import Foundation
import Testing
@testable import BoopstashCore

@Suite struct ThemeTests {
    @Test func themesAreUniqueAndComplete() {
        #expect(Set(Theme.all.map(\.id)).count == Theme.all.count)
        #expect(!Theme.all.contains { $0.id == Theme.systemID })
        for theme in Theme.all {
            #expect(Set(theme.roles.keys) == Set(HighlightRole.allCases), "\(theme.id) misses a role")
        }
    }

    @Test func bothAppearancesHaveChoices() {
        #expect(Theme.all.filter(\.isDark).count >= 3)
        #expect(Theme.all.filter { !$0.isDark }.count >= 3)
    }

    @Test func darkThemesAreDarkAndLightThemesLight() {
        for theme in Theme.all {
            #expect((theme.background.luminance < 0.2) == theme.isDark, "\(theme.id)")
        }
    }

    /// Text must be readable: body text at WCAG AA (4.5), highlighted text
    /// at least 3 (large-text AA), comments, which every one of these
    /// schemes dims on purpose, at least 2.
    ///
    /// Solarized Light is the one exception, and a deliberate one: its
    /// published palette is low-contrast by design (body text 4.13, yellow,
    /// cyan and green about 2.9 on its background). It is kept as published
    /// rather than altered, with floors just under its own values, so a
    /// typo in its table still fails.
    static let publishedLowContrast: [String: (text: Double, role: Double)] = [
        "solarized-light": (text: 4.1, role: 2.9),
    ]

    @Test(arguments: Theme.all)
    func contrastIsReadable(_ theme: Theme) {
        let floors = Self.publishedLowContrast[theme.id] ?? (text: 4.5, role: 3.0)
        #expect(theme.foreground.contrast(with: theme.background) >= floors.text, "\(theme.id) text")
        for role in HighlightRole.allCases {
            let ratio = theme.color(for: role).contrast(with: theme.background)
            let floor = role == .comment ? 2.0 : floors.role
            #expect(ratio >= floor, "\(theme.id) \(role): \(String(format: "%.2f", ratio))")
        }
    }

    @Test func hexParses() {
        let c = ThemeColor("#ff8000")
        #expect(c.red == 1 && c.green == Double(0x80) / 255 && c.blue == 0)
        #expect(ThemeColor("#ffffff").contrast(with: ThemeColor("#000000")) > 20.9)
    }

    @Test(arguments: [
        ("comment", HighlightRole?.some(.comment)), ("string", .string), ("string.escape", .escape),
        ("number", .number), ("keyword.function", .keyword), ("function.method", .function),
        ("type.builtin", .type), ("property", .property), ("variable.builtin", .builtin),
        ("variable", nil), ("punctuation.bracket", nil), ("text.title", .heading),
        ("text.uri", .link), ("diff.plus", .added), ("diff.minus", .removed),
    ])
    func capturesMapToRoles(_ capture: String, _ role: HighlightRole?) {
        #expect(HighlightRole.role(for: capture) == role)
    }

    @Test func appearanceResolvesThemesAndClampsSize() {
        let appearance = EditorAppearance(fontSize: 99, lightThemeID: "solarized-light", darkThemeID: "nord")
        #expect(appearance.fontSize == 36)
        #expect(appearance.theme(dark: false)?.id == "solarized-light")
        #expect(appearance.theme(dark: true)?.id == "nord")
        #expect(EditorAppearance().theme(dark: true) == nil, "system")
        #expect(EditorAppearance(lightThemeID: "retired-theme").theme(dark: false) == nil)
    }
}
