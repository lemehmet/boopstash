import AppKit
import BoopstashCore
import UniformTypeIdentifiers

/// Help ▸ Report a Problem… and Help ▸ Copy as GitHub Issue (#185). A
/// report is an ordinary local note labelled `bug`: facts about the app and
/// the screen, never any note's text or title. Nothing is sent anywhere;
/// copying it as an issue writes the clipboard and opens the bare new-issue
/// page, and the user decides what to paste.
extension AppModel {
    /// The choices the sheet offers, both on by default.
    struct ProblemReportOptions {
        var screenshot = true
        var logs = true
    }

    // MARK: Facts

    func problemReportEnvironment(defaults: UserDefaults = .standard) -> ProblemReport.Environment {
        let sync: ProblemReport.Sync
        if !canSync {
            sync = .unavailable
        } else if showsSyncing {
            sync = .on(lastSynced: lastSynced, problem: syncAccountProblem ?? syncProblem)
        } else {
            sync = .off
        }
        let preset = defaults.string(forKey: "keymapPreset").flatMap(KeymapPreset.init(rawValue:)) ?? .vsCode
        return ProblemReport.Environment(
            appVersion: LiveDiagnostics.appVersion, build: LiveDiagnostics.build,
            distribution: LiveDiagnostics.distribution,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: LiveDiagnostics.chip, appleIntelligence: LiveModelTitler.availabilityDescription,
            iCloudEnvironment: LiveSyncEngine.environment, sync: sync,
            semanticSearch: semanticSearchEnabled(), keymapPreset: preset.displayName,
            linuxHabits: defaults.bool(forKey: "linuxHabits"))
    }

    /// The selected note, described without its text: the editor showing
    /// it, if any, says what it highlights and what is folded.
    func problemReportNote(editor: BoopTextView?, defaults: UserDefaults = .standard) -> ProblemReport.SelectedNote? {
        guard let id = selection, let note = note(id: id) else { return nil }
        let language: SyntaxLanguage?
        let detected: Bool
        if let editor {
            language = editor.syntax.currentLanguage
            detected = editor.syntax.choice == .automatic
        } else {
            language = note.syntaxChoice.resolve(for: note.body)
            detected = note.syntaxChoice == .automatic
        }
        let preview: ProblemReport.SelectedNote.Preview =
            !defaults.bool(forKey: PreviewSettings.shownKey) ? .hidden
            : (defaults.object(forKey: PreviewSettings.sideBySideKey) as? Bool ?? true) ? .beside : .replacing
        return ProblemReport.SelectedNote(
            id: id, body: note.body, language: language?.displayName, languageDetected: detected,
            attachments: (try? store.attachments(referencedBy: note.body).count) ?? 0,
            folds: editor?.folding.folded.count, preview: preview)
    }

    /// The list's filter, without its text.
    func problemReportList() -> ProblemReport.List {
        let labels = query.labels.compactMap { try? store.label(id: $0)?.name }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let similar = similarTo.map { $0 == selection ? "on, for the selected note" : "on, for another note" } ?? "off"
        return ProblemReport.List(scope: query.scope.rawValue, days: query.days, labels: labels,
                                  hasFilterText: !query.text.isEmpty, similarNotes: similar)
    }

    // MARK: Creating

    /// Makes the report note, labels it `bug` (made again if it was
    /// deleted) and selects it. The facts must be gathered before: saving
    /// a note clears the list's filter and moves the selection.
    @discardableResult
    func createProblemReport(environment: ProblemReport.Environment, note selected: ProblemReport.SelectedNote?,
                             list: ProblemReport.List, logLines: [String]?, logError: String? = nil,
                             screenshot: Data?, now: Date = Date()) -> Note? {
        var note = Note(title: ProblemReport.title(for: now), body: "", createdAt: now)
        // The title stays: the model never renames a report.
        note.titleIsUserSet = true
        var attachment: NoteAttachment?
        var screenshotProblem: String?
        if let screenshot {
            if case .success = ImageImport.check(screenshot, type: .png) {
                do {
                    attachment = try store.addAttachment(screenshot, contentType: UTType.png.identifier, noteID: note.id, now: now)
                } catch {
                    Log.diagnostics.error("screenshot not saved: \(error.localizedDescription, privacy: .private)")
                    screenshotProblem = error.localizedDescription
                }
            } else {
                screenshotProblem = "the image was empty or too large"
            }
        }
        let report = ProblemReport(createdAt: now, environment: environment, note: selected, list: list, logLines: logLines,
                                   logError: logError,
                                   screenshot: attachment.map { AttachmentReference.markdown(for: $0.id, alt: "Screenshot") })
        note.body = report.markdown()
        guard insert(note) else {
            if let attachment { try? store.deleteAttachment(id: attachment.id) }
            return nil
        }
        if let screenshotProblem {
            banner = "The report was made without its screenshot: \(screenshotProblem)"
        }
        var labelled: Set<UUID> = []
        do {
            let label = try store.labelCreatingIfMissing(named: ProblemReport.labelName, color: ProblemReport.labelColor, now: now)
            try store.assignLabel(label.id, to: note.id)
            labelled = [label.id]
        } catch {
            banner = "The report was made, but could not be labelled \(ProblemReport.labelName): \(error.localizedDescription)"
        }
        // A label filter the report does not carry would hide it while it
        // is selected: only `bug`, if filtered by, stays.
        if !query.labels.isSubset(of: labelled) { query.labels.formIntersection(labelled) }
        Log.diagnostics.info("problem report made: screenshot \(attachment != nil), logs \(logLines != nil)")
        return note
    }

    /// Help ▸ Copy as GitHub Issue: the selected note as Markdown for an
    /// issue, attachments replaced by a line asking for the image by hand,
    /// then the bare new-issue page in the browser. The app itself makes
    /// no request; the browser opens a page with nothing in its URL.
    @discardableResult
    func copySelectionAsGitHubIssue(pasteboard: NSPasteboard = .general,
                                    open: (URL) -> Void = { NSWorkspace.shared.open($0) },
                                    write: (NSPasteboard, String) -> Bool = { $0.clearContents(); return $0.setString($1, forType: .string) }) -> Bool {
        guard let id = selection, let note = note(id: id) else {
            NSSound.beep()
            return false
        }
        // Nothing copied, nothing to paste: the browser stays shut.
        guard write(pasteboard, ProblemReport.issueMarkdown(note.body)) else {
            banner = "Could not copy the note to the clipboard."
            return false
        }
        open(ProblemReport.newIssueURL)
        banner = AttachmentReference.ids(in: note.body).isEmpty
            ? "Copied as Markdown: paste it into the new issue."
            : "Copied as Markdown: paste it into the new issue, then drag the screenshot in from the note."
        return true
    }
}

/// The sheet and its flow, from the Help menu.
@MainActor
enum ProblemReportSheet {
    /// Takes the screenshot and the facts now, while the window is as the
    /// user left it, then asks. The sheet hangs on the window the user was
    /// in; with none, it is a dialog and there is no screenshot.
    static func run(model: AppModel) {
        let window = NSApp.keyWindow.map { $0.sheetParent ?? $0 } ?? NSApp.mainWindow
        let screenshot = window.flatMap(LiveDiagnostics.png(of:))
        let environment = model.problemReportEnvironment()
        let note = model.problemReportNote(editor: window.flatMap(LiveDiagnostics.editor(in:)))
        let list = model.problemReportList()
        let started = Date()

        let alert = NSAlert()
        alert.messageText = "Report a Problem"
        alert.informativeText = """
            Makes a note labelled \(ProblemReport.labelName) describing BoopStash and this window, without the text of any note. \
            It is an ordinary note: with Sync with iCloud on, it syncs to your devices like any other. \
            Nobody else sees it unless you share it.
            """
        let shot = NSButton(checkboxWithTitle: "Include a screenshot of this window", target: nil, action: nil)
        shot.state = screenshot == nil ? .off : .on
        shot.isEnabled = screenshot != nil
        let logs = NSButton(checkboxWithTitle: "Include recent BoopStash log lines", target: nil, action: nil)
        logs.state = .on
        let stack = NSStackView(views: [shot, logs])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: stack.fittingSize.height)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let options = AppModel.ProblemReportOptions(screenshot: shot.state == .on, logs: logs.state == .on)
            Task { @MainActor in
                let since = started.addingTimeInterval(-ProblemReport.logWindow)
                var lines: [String]?
                var logError: String?
                if options.logs {
                    do {
                        lines = try await Task.detached(priority: .userInitiated) { try LiveDiagnostics.recentLog(since: since) }.value
                    } catch {
                        logError = error.localizedDescription
                    }
                }
                model.createProblemReport(environment: environment, note: note, list: list, logLines: lines, logError: logError,
                                          screenshot: options.screenshot ? screenshot : nil)
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
