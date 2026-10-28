import AppKit
import BoopstashCore
import CoreTransferable
import UniformTypeIdentifiers

/// Text or text files dropped on the note list become notes. The same type
/// policy as the clipboard applies: a password manager's drag is refused.
@MainActor
enum DropCapture {
    static let acceptedTypes: [UTType] = [.fileURL, .utf8PlainText, .plainText]

    /// Handles a drop; false when nothing in it could be used.
    static func handle(_ providers: [NSItemProvider], model: AppModel) -> Bool {
        let usable = providers.filter { provider in acceptedTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) } }
        guard !usable.isEmpty else { return false }
        // Where the drop came from is decided now, at the drop: by the time a
        // slow item has loaded, another app may be in front (#31), and every
        // item of one drop shares one source.
        let source = model.dropSource()
        Task {
            for provider in usable { await capture(provider, model: model, source: source) }
        }
        return true
    }

    private static func capture(_ provider: NSItemProvider, model: AppModel, source: (bundleID: String?, name: String?)?) async {
        switch CapturePolicy.decide(types: provider.registeredTypeIdentifiers) {
        case .accept: break
        case .refuseConcealed:
            model.banner = "Not saved: the drop holds a password manager item."
            return
        case .refuseTransient:
            model.banner = "Not saved: the app it came from marked it as not to be kept."
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            guard let url = await load(URL.self, from: provider) else {
                model.banner = "Could not read the dropped file."
                return
            }
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            let type = values?.contentType
            // Refuse what the file system already rules out before reading a
            // byte: a known binary type, or more than the limit.
            if let type, !TextFileImport.accepts(type) {
                model.banner = "\(url.lastPathComponent) is not a text file."
                return
            }
            if let size = values?.fileSize, size > TextFileImport.sizeLimit {
                model.banner = "\(url.lastPathComponent) is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)); the limit is 5 MB."
                return
            }
            // A file dropped from Finder can be read for this drop only;
            // the sandbox grants nothing beyond it. The size is checked again
            // after reading, in case the file grew.
            // Never more than the limit plus one byte, so a file that grew
            // since the size check, or one with no size (a pipe), cannot be
            // read without bound (#30). The extra byte means "too large".
            guard let data = readPrefix(of: url, limit: TextFileImport.sizeLimit + 1) else {
                model.banner = "Could not read \(url.lastPathComponent)."
                return
            }
            switch TextFileImport.text(from: data, type: type) {
            case .success(let text):
                model.save(text, origin: .drop, title: TextFileImport.title(forFileNamed: url.lastPathComponent),
                           sourceBundleID: source?.bundleID, sourceAppName: source?.name)
            case .failure(.notText):
                model.banner = "\(url.lastPathComponent) is not a text file."
            case .failure(.tooLarge(let bytes)):
                model.banner = "\(url.lastPathComponent) is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); the limit is 5 MB."
            case .failure(.unreadable):
                model.banner = "Could not read \(url.lastPathComponent) as text."
            }
        } else {
            // The drop was accepted, so every way it can come to nothing is
            // reported rather than silent.
            guard let text = await load(String.self, from: provider) else {
                model.banner = "Could not read the dropped text."
                return
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.banner = "The dropped text is empty."
                return
            }
            model.save(text, origin: .drop, sourceBundleID: source?.bundleID, sourceAppName: source?.name)
        }
    }

    /// Up to `limit` bytes from the start of the file.
    static func readPrefix(of url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: limit) ?? Data()
    }

    private static func load<T: Transferable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: type) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }
}
