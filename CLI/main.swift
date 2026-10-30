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
// Never created here: the app moves its own store, sync state and all, into
// the group on first launch. A store made here first would leave that state
// behind in a merge.
let storeURL = group.appendingPathComponent("Library/Application Support/Boopstash/notes.sqlite")
guard FileManager.default.fileExists(atPath: storeURL.path) else {
    write("boopstash: no notes to reach yet; open BoopStash once first\n", to: .standardError)
    exit(69)
}
let store: NoteStore
do {
    store = try NoteStore.open(at: storeURL, shared: true)
} catch {
    write("boopstash: could not open the notes: \(error.localizedDescription)\n", to: .standardError)
    exit(74)
}
// At most one byte past the limit, so an endless pipe cannot fill memory.
let output = CommandLineTool.run(command, store: store, input: {
    var data = Data()
    // A read error throws, and nothing is kept; only an empty read is the end.
    while data.count <= CommandLineTool.inputLimit,
          let chunk = try FileHandle.standardInput.read(upToCount: CommandLineTool.inputLimit + 1 - data.count), !chunk.isEmpty {
        data.append(chunk)
    }
    return data
}, version: version)
write(output.standardOutput, to: .standardOutput)
write(output.standardError, to: .standardError)
// The app's list does not see another process's writes by itself.
if output.wrote { notify_post(changed) }
exit(output.status)
