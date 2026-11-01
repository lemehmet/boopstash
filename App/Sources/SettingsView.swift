import BoopstashCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel?
    @Binding var preset: KeymapPreset
    @Binding var linuxHabits: Bool
    /// The tab last shown, kept between openings (and chosen by the
    /// screenshots).
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings(model: model) }
            Tab("Editor", systemImage: "textformat", value: "editor") { EditorSettingsView() }
            Tab("Keyboard", systemImage: "keyboard", value: "keyboard") { KeyboardSettings(preset: $preset, linuxHabits: $linuxHabits) }
            Tab("Labels", systemImage: "tag", value: "labels") { LabelSettings(model: model) }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    /// Observed, so script problems update as the folder changes.
    let model: AppModel?
    @AppStorage(AppModel.modelTitlesKey) private var modelTitles = true
    @AppStorage(AppDelegate.hotKeyKey) private var globalShortcut = true
    @AppStorage(AppModel.semanticSearchKey) private var semanticSearch = true
    @AppStorage(CommandLineInstaller.linkPathKey) private var linkPath = ""
    /// `linkPath` once checked to still run this app's command.
    @State private var verifiedLinkPath: String?

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("⌃⌥⌘V saves the clipboard from any app", isOn: $globalShortcut)
                Text("Also in every app's Services menu: select text, then Services ▸ Save to BoopStash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Search") {
                Toggle("Find notes by meaning", isOn: $semanticSearch)
                    .onChange(of: semanticSearch) { model?.semanticSearchChanged() }
                Text("A small language model bundled with BoopStash reads each note on this Mac, so a search also finds notes that say the same in other words. Nothing leaves this Mac.")
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
            Section("Scripts") {
                LabeledContent("Your scripts") {
                    Button("Show Scripts Folder") { UserScriptsFolder.reveal() }
                }
                Text("Boop scripts dropped in this folder appear in Scripts ▸ Run Script… (⌘B). One named like a built-in script replaces it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let problems = (model?.scriptLibrary ?? ScriptLibrary.all()).problems.filter { $0.scriptID.hasPrefix("user/") }
                if !problems.isEmpty {
                    Text(problems.map { "\($0.scriptID.dropFirst("user/".count)): \($0.message)" }.joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Command line") {
                LabeledContent("boopstash command") {
                    Button("Install…") { CommandLineInstaller.run() }
                }
                Text(verifiedLinkPath.map { "Linked at \($0). Pipe text into a new note from Terminal: some-command | boopstash." }
                     ?? "Pipe text into a new note from Terminal: some-command | boopstash. Install links the command into a folder on your PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .task(id: linkPath) { verifiedLinkPath = CommandLineInstaller.verifiedLinkPath(linkPath) }
            }
            if let model { SyncSettings(model: model) }
            Section("Clipboard history") {
                Text("BoopStash never watches the clipboard. For a history of what you copied, macOS has one: turn on System Settings ▸ Spotlight ▸ Clipboard, then press ⌘Space and ⌘4.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings ▸ General ▸ iCloud (#64). Off by default; nothing contacts
/// iCloud, not even to check the account, until it is turned on.
struct SyncSettings: View {
    let model: AppModel
    @AppStorage(AppModel.syncKey) private var enabled = false

    var body: some View {
        Section("iCloud") {
            Toggle("Sync with iCloud", isOn: Binding(get: { (enabled || model.demoSync) && model.canSync }, set: { if !model.demoSync { model.setSyncEnabled($0) } }))
                .disabled(!model.canSync)
            if !model.canSync {
                Text("This build of BoopStash was not signed for iCloud, so it cannot sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if enabled {
                // Shown whenever sync is on, also when it could not start.
                if let problem = model.syncAccountProblem ?? model.syncProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            if model.canSync, model.showsSyncing {
                LabeledContent("Last synced") {
                    HStack {
                        Text(model.lastSynced.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet")
                        Button("Sync Now") { model.syncNow() }
                    }
                }
            }
            Text("Notes and images go to your own iCloud, in fields encrypted on this Mac. With Advanced Data Protection they are end-to-end encrypted; without it, Apple holds the keys, as for most iCloud data.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings ▸ Editor: font and themes (ADR 0003 keeps the editor plain; its
/// look is the user's).
struct EditorSettingsView: View {
    @AppStorage(EditorSettings.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = 13.0
    @AppStorage(EditorSettings.lightThemeKey) private var lightTheme = Theme.systemID
    @AppStorage(EditorSettings.darkThemeKey) private var darkTheme = Theme.systemID
    @AppStorage(EditorSettings.tabWidthKey) private var tabWidth = 2
    @AppStorage(EditorSettings.singleQuoteKey) private var singleQuote = false
    @AppStorage(EditorSettings.sqlDialectKey) private var sqlDialect = "sql"
    @AppStorage(EditorSettings.keywordCaseKey) private var keywordCase = FormatSettings.KeywordCase.preserve.rawValue
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
            Section("Formatting") {
                Stepper(value: $tabWidth, in: 1...8) {
                    LabeledContent("Indent width", value: "\(tabWidth) spaces")
                }
                Toggle("Prefer single quotes in JavaScript and TypeScript", isOn: $singleQuote)
                Picker("SQL dialect", selection: $sqlDialect) {
                    ForEach(FormatSettings.sqlDialects, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("SQL keywords", selection: $keywordCase) {
                    Text("As written").tag(FormatSettings.KeywordCase.preserve.rawValue)
                    Text("UPPER CASE").tag(FormatSettings.KeywordCase.upper.rawValue)
                    Text("lower case").tag(FormatSettings.KeywordCase.lower.rawValue)
                }
                Text("Edit ▸ Format Document formats JSON and XML natively; JavaScript, TypeScript, CSS, HTML, YAML and Markdown with Prettier; SQL with sql-formatter; Python with Ruff, Go with gofmt, shell with shfmt, and C, C++ and Java with clang-format, all in BoopStash's sandboxed script process.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("macOS gives Ctrl+← and Ctrl+→ to Mission Control. Change those in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Mission Control for them to reach BoopStash.")
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
    static let tabWidthKey = "formatTabWidth"
    static let singleQuoteKey = "formatSingleQuote"
    static let sqlDialectKey = "formatSQLDialect"
    static let keywordCaseKey = "formatSQLKeywordCase"

    /// Format Document's options, as Settings ▸ Editor ▸ Formatting has them.
    nonisolated static func formatSettings(_ defaults: UserDefaults = .standard) -> FormatSettings {
        FormatSettings(tabWidth: defaults.object(forKey: tabWidthKey) as? Int ?? 2,
                       singleQuote: defaults.bool(forKey: singleQuoteKey),
                       sqlDialect: defaults.string(forKey: sqlDialectKey) ?? "sql",
                       keywordCase: defaults.string(forKey: keywordCaseKey).flatMap(FormatSettings.KeywordCase.init) ?? .preserve)
    }

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
