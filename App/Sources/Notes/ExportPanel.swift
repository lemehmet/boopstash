import AppKit
import BoopstashCore

/// File ▸ Export All Notes…: asks for a folder, then writes every note into
/// a new dated folder inside it, so an export never mixes with what is there.
@MainActor
enum ExportPanel {
    static func run(model: AppModel) {
        // Exporting reads the store; an edit that could not be saved would be
        // missing from the export while it claimed success.
        guard model.flushAll() else {
            model.banner = "Export cancelled: some edits could not be saved. \(model.banner ?? "")"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to put the exported notes. A new folder is created inside it."
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        do {
            let notes = try model.store.notes(matching: NoteQuery(limit: Int(Int32.max)))
            let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
            var folder = parent.appendingPathComponent("Boopstash export \(stamp)")
            var counter = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = parent.appendingPathComponent("Boopstash export \(stamp) \(counter)")
                counter += 1
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for file in NoteExport.files(for: notes) {
                try file.contents.write(to: folder.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
            }
            model.banner = "Exported \(notes.count) note\(notes.count == 1 ? "" : "s")."
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            model.banner = "Export failed: \(error.localizedDescription)"
        }
    }
}
