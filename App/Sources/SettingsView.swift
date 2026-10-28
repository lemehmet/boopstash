import BoopstashCore
import SwiftUI

struct SettingsView: View {
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
            Section("Clipboard history") {
                Text("Boopstash never watches the clipboard. For a history of what you copied, macOS has one: turn on System Settings ▸ Spotlight ▸ Clipboard, then press ⌘Space and ⌘4.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
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
            // Boopstash key bindings, in VS Code's keybindings.json format.
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
