import BoopstashCore
import Foundation
import MachO
import notify

// `boopstash` (#156, ADR 0009): a thin shell around BoopstashCore's
// CommandLineTool. Sandboxed; it reaches only the App Group's store and
// standard input and output.

let groupID = "A658882T2K.com.lemehmet.boopstash"
let changed = "com.lemehmet.boopstash.changed"

func write(_ text: String, to handle: FileHandle) {
    if !text.isEmpty { handle.write(Data(text.utf8)) }
}

let command: CommandLineTool.Command
do {
    command = try CommandLineTool.parse(Array(CommandLine.arguments.dropFirst()), standardInputIsTerminal: isatty(STDIN_FILENO) == 1)
} catch {
    write("boopstash: \(error.message)\n\n\(CommandLineTool.usage)\n", to: .standardError)
    exit(64)
}

// The version from the Info.plist inside this binary: run through
// Homebrew's link, Bundle.main looks in the link's folder.
let version: String = {
    var size: UInt = 0
    guard let bytes = getsectiondata(#dsohandle.assumingMemoryBound(to: mach_header_64.self), "__TEXT", "__info_plist", &size),
          let plist = try? PropertyListSerialization.propertyList(from: Data(bytes: bytes, count: Int(size)), format: nil) as? [String: Any]
    else { return "unknown" }
    return plist["CFBundleShortVersionString"] as? String ?? "unknown"
}()
if command == .help || command == .version {
    let output = CommandLineTool.run(command, store: try! NoteStore.inMemory(), input: { Data() }, version: version)
    write(output.standardOutput, to: .standardOutput)
    exit(0)
}

guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
    write("boopstash: this copy of BoopStash cannot reach its notes (no App Group)\n", to: .standardError)
    exit(69)
}
// Created if the app has not run yet: the app merges it with its own when
// it next starts (NoteStore.sharedStoreFolder).
let storeURL = group.appendingPathComponent("Library/Application Support/Boopstash/notes.sqlite")
let store: NoteStore
do {
    store = try NoteStore.open(at: storeURL, shared: true)
} catch {
    write("boopstash: could not open the notes: \(error.localizedDescription)\n", to: .standardError)
    exit(74)
}
let output = CommandLineTool.run(command, store: store, input: { FileHandle.standardInput.readDataToEndOfFile() }, version: version)
write(output.standardOutput, to: .standardOutput)
write(output.standardError, to: .standardError)
// The app's list does not see another process's writes by itself.
if output.wrote { notify_post(changed) }
exit(output.status)
