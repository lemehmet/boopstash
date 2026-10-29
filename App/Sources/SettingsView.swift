import BoopstashCore
import SwiftUI

struct SettingsView: View {
    @Binding var preset: KeymapPreset
    @Binding var linuxHabits: Bool

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Editor", systemImage: "textformat") { EditorSettingsView() }
            Tab("Keyboard", systemImage: "keyboard") { KeyboardSettings(preset: $preset, linuxHabits: $linuxHabits) }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @AppStorage(AppModel.modelTitlesKey) private var modelTitles = true
    @AppStorage(AppDelegate.hotKeyKey) private var globalShortcut = true

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("⌃⌥⌘V saves the clipboard from any app", isOn: $globalShortcut)
                Text("Also in every app's Services menu: select text, then Services ▸ Save to Boopstash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Titles") {
                Toggle("Name notes with Apple Intelligence", isOn: $modelTitles)
                    .disabled(!LiveModelTitler.isAvailable)
                Text(LiveModelTitler.isAvailable
                     ? "Uses the on-device model only; note text never leaves this Mac. Notes you name yourself are never renamed."
                     : "Apple Intelligence is not available on this Mac, so titles come from each note's first meaningful line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Clipboard history") {
                Text("BoopStash never watches the clipboard. For a history of what you copied, macOS has one: turn on System Settings ▸ Spotlight ▸ Clipboard, then press ⌘Space and ⌘4.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings ▸ Editor: font and themes (ADR 0003 keeps the editor plain; its
/// look is the user's).
struct EditorSettingsView: View {
    @AppStorage(EditorSettings.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = 13.0
    @AppStorage(EditorSettings.lightThemeKey) private var lightTheme = Theme.systemID
    @AppStorage(EditorSettings.darkThemeKey) private var darkTheme = Theme.systemID
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $fontFamily) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(EditorSettings.monospacedFamilies(), id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $fontSize, in: EditorAppearance.fontSizes, step: 1) {
                    LabeledContent("Size", value: "\(Int(fontSize)) pt")
                }
            }
            Section {
                ThemePicker(title: "Light appearance", selection: $lightTheme)
                ThemePicker(title: "Dark appearance", selection: $darkTheme)
                Text("The editor follows macOS between light and dark. Any theme can be used for either.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Theme")
            }
            Section("Preview") {
                ThemePreview(appearance: EditorAppearance(fontFamily: fontFamily, fontSize: fontSize,
                                                          lightThemeID: lightTheme, darkThemeID: darkTheme),
                             dark: colorScheme == .dark)
            }
        }
        .formStyle(.grouped)
    }
}

struct ThemePicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            Text("System").tag(Theme.systemID)
            Divider()
            Section("Light") {
                ForEach(Theme.all.filter { !$0.isDark }) { Text($0.name).tag($0.id) }
            }
            Section("Dark") {
                ForEach(Theme.all.filter(\.isDark)) { Text($0.name).tag($0.id) }
            }
        }
    }
}

/// A few lines coloured the way the editor will colour them.
struct ThemePreview: View {
    let appearance: EditorAppearance
    let dark: Bool

    static let sample: [(String, HighlightRole?)] = [
        ("// Stash anything\n", .comment), ("func ", .keyword), ("greet", .function), ("(", nil),
        ("name", nil), (": ", nil), ("String", .type), (") -> ", nil), ("Int", .type), (" {\n    ", nil),
        ("let ", .keyword), ("count = ", nil), ("42", .number), ("\n    print(", nil),
        ("\"Hello, \\(name)\"", .string), (")\n}", nil),
    ]

    var body: some View {
        let theme = appearance.theme(dark: dark)
        let font = Font(EditorSettings.font(for: appearance))
        Text(Self.attributed(theme: theme))
            .font(font)
            .textSelection(.disabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(theme.map { Color(nsColor: NSColor($0.background)) } ?? Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
    }

    static func attributed(theme: Theme?) -> AttributedString {
        var result = AttributedString()
        for (text, role) in sample {
            var piece = AttributedString(text)
            let color: NSColor = role.map { r in theme.map { NSColor($0.color(for: r)) } ?? SyntaxTheme.systemColor(for: r) }
                ?? (theme.map { NSColor($0.foreground) } ?? .textColor)
            piece.foregroundColor = Color(nsColor: color)
            result += piece
        }
        return result
    }
}

struct KeyboardSettings: View {
    @Binding var preset: KeymapPreset
    @Binding var linuxHabits: Bool

    var body: some View {
        Form {
            Section("Keyboard") {
                Picker("Key bindings", selection: $preset) {
                    ForEach(KeymapPreset.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Linux habits (Ctrl+arrows move by word)", isOn: $linuxHabits)
                if linuxHabits {
                    Text("macOS gives Ctrl+← and Ctrl+→ to Mission Control. Change those in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control for them to reach Boopstash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Custom bindings") {
                    Button("Show keybindings.json") { KeybindingsFile.reveal() }
                }
                let file = KeybindingsFile.load()
                let problems = Keymap(overrides: file.overrides, fileProblems: file.problems).problems
                if !problems.isEmpty {
                    Text(problems.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Where Settings ▸ Editor keeps its values, and the font they describe.
enum EditorSettings {
    static let fontFamilyKey = "editorFontFamily"
    static let fontSizeKey = "editorFontSize"
    static let lightThemeKey = "editorLightTheme"
    static let darkThemeKey = "editorDarkTheme"

    /// Installed families whose regular face is fixed-pitch.
    static func monospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) else { return false }
            return font.isFixedPitch && !family.hasPrefix(".")
        }
    }

    static func font(for appearance: EditorAppearance) -> NSFont {
        let size = CGFloat(appearance.fontSize)
        guard !appearance.fontFamily.isEmpty,
              let font = NSFontManager.shared.font(withFamily: appearance.fontFamily, traits: [], weight: 5, size: size)
        else { return .monospacedSystemFont(ofSize: size, weight: .regular) }
        return font
    }
}

/// The user's `keybindings.json`, in VS Code's format, inside the app's
/// container. Created on first reveal so there is something to edit.
enum KeybindingsFile {
    static var url: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Boopstash/keybindings.json")
    }

    /// A missing file is no overrides; a file that cannot be read or is not
    /// a JSON array is reported, so a typo never silently resets bindings.
    static func load() -> Keymap.OverridesFile {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return .init(overrides: [], problems: [])
        }
        do {
            return try Keymap.overrides(fromJSON: Data(contentsOf: url))
        } catch {
            return .init(overrides: [], problems: ["keybindings.json could not be read: \(error.localizedDescription)"])
        }
    }

    @MainActor
    static func reveal() {
        guard let url else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = """
            // BoopStash key bindings, in VS Code's keybindings.json format.
            // Commands are listed in docs/adr/0003; prefix one with "-" to remove a binding.
            [
              // { "key": "cmd+d", "command": "duplicateLineDown" },
            ]

            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
