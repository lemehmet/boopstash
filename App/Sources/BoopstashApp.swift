import BoopstashCore
import SwiftUI

@main
struct BoopstashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("keymapPreset") private var preset: KeymapPreset = .vsCode
    @AppStorage("linuxHabits") private var linuxHabits = false
    @AppStorage(PreviewSettings.shownKey) private var previewShown = false
    @AppStorage(PreviewSettings.sideBySideKey) private var previewSideBySide = true
    @AppStorage(EditorSettings.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = 13.0
    @AppStorage(EditorSettings.lightThemeKey) private var lightTheme = Theme.systemID
    @AppStorage(EditorSettings.darkThemeKey) private var darkTheme = Theme.systemID

    private var appearance: EditorAppearance {
        EditorAppearance(fontFamily: fontFamily, fontSize: fontSize, lightThemeID: lightTheme, darkThemeID: darkTheme)
    }

    private var keymap: Keymap {
        let file = KeybindingsFile.load()
        return Keymap(preset: preset, linuxHabits: linuxHabits, overrides: file.overrides, fileProblems: file.problems)
    }

    var body: some Scene {
        WindowGroup {
            if let model = delegate.model {
                MainWindow(model: model, keymap: keymap, appearance: appearance)
                    .frame(minWidth: 720, minHeight: 420)
            } else {
                ContentUnavailableView("BoopStash could not open its notes", systemImage: "exclamationmark.triangle",
                                       description: Text(delegate.openError ?? ""))
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { delegate.model?.newNote() }
                    .keyboardShortcut("n")
                Button("New Note from Clipboard") { delegate.model?.captureClipboard() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandGroup(before: .sidebar) {
                // ⇧⌘V belongs to Paste as Markdown, so the preview is ⌥⌘P.
                Toggle("Show Preview", isOn: $previewShown)
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Toggle("Preview Beside the Editor", isOn: $previewSideBySide)
                Divider()
            }
            CommandGroup(after: .saveItem) {
                Button("Export All Notes…") {
                    if let model = delegate.model { ExportPanel.run(model: model) }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste as Markdown") {
                    NSApp.sendAction(#selector(BoopTextView.pasteAsMarkdown(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .option, .shift])
                // A SwiftUI command is not validated through the responder
                // chain, so it follows the editor's focus explicitly (#25).
                .disabled(!(delegate.model?.editorHasFocus ?? false))
            }
            ScriptCommands(model: delegate.model)
            CommandGroup(after: .textEditing) {
                // Shortcuts come from the key-binding preset (⇧⌥F in VS Code,
                // ⌥⌘L in JetBrains), so the menu shows none of its own.
                Button("Format Document") {
                    NSApp.sendAction(#selector(BoopTextView.formatDocument(_:)), to: nil, from: nil)
                }
                .disabled(!(delegate.model?.canFormatDocument ?? false))
                Button("Format JSON, Sorting Keys") {
                    NSApp.sendAction(#selector(BoopTextView.formatJSONSortingKeys(_:)), to: nil, from: nil)
                }
                .disabled(!(delegate.model?.canSortJSONKeys ?? false))
            }
        }

        Settings {
            SettingsView(preset: $preset, linuxHabits: $linuxHabits)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel?
    let openError: String?

    override init() {
        do {
            model = try AppModel.live()
            openError = nil
        } catch {
            model = nil
            openError = error.localizedDescription
        }
        super.init()
    }

    private var hotKey: GlobalHotKey?
    private var reportedHotKeyFailure = false
    private var services: ServicesProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        let provider = ServicesProvider(model: model)
        services = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        updateHotKey()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHotKey() }
        }
    }

    static let hotKeyKey = "globalCaptureShortcut"

    /// Settings ▸ "⌃⌥⌘V saves the clipboard from any app", on by default.
    private func updateHotKey() {
        let enabled = UserDefaults.standard.object(forKey: Self.hotKeyKey) as? Bool ?? true
        if enabled, hotKey == nil, let model {
            hotKey = GlobalHotKey.captureClipboard { model.captureClipboard(origin: .hotKey) }
            // Left nil on failure, so the next settings change tries again.
            if hotKey == nil, !reportedHotKeyFailure {
                reportedHotKeyFailure = true
                model.banner = "⌃⌥⌘V is taken by another app. Capture with ⌥⌘N or Services ▸ Save to BoopStash instead."
            }
        } else if !enabled, let hotKey {
            hotKey.unregister()
            self.hotKey = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.flushAll()
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    /// This window's script picker; every window has its own.
    @State private var scriptPicker: PickerTarget?
    let keymap: Keymap
    let appearance: EditorAppearance

    var body: some View {
        NavigationSplitView {
            NoteList(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if let id = model.selection, let note = model.note(id: id) {
                NoteDetail(model: model, note: note, keymap: keymap, appearance: appearance)
                    .id(id)
            } else {
                ContentUnavailableView("No note selected", systemImage: "note.text")
            }
        }
        .onChange(of: model.selection) { old, _ in
            guard let old else { return }
            model.flush(old)
            if let note = model.note(id: old) { model.requestModelTitle(for: note) }
        }
        .sheet(item: $scriptPicker) { target in
            ScriptPicker(model: model, target: target)
        }
        .focusedSceneValue(\.scriptPicker, $scriptPicker)
        .safeAreaInset(edge: .bottom) {
            if let banner = model.banner {
                HStack {
                    Text(banner)
                    Spacer()
                    Button("Dismiss") { model.banner = nil }
                        .buttonStyle(.borderless)
                }
                .padding(8)
                .background(.bar)
                .task(id: banner) {
                    try? await Task.sleep(for: .seconds(6))
                    if model.banner == banner { model.banner = nil }
                }
            }
        }
    }
}
