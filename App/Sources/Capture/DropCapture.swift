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
        Task {
            for provider in usable { await capture(provider, model: model) }
        }
        return true
    }

    private static func capture(_ provider: NSItemProvider, model: AppModel) async {
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
            guard let url = await load(URL.self, from: provider) else { return }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            // A file dropped from Finder can be read for this drop only;
            // the sandbox grants nothing beyond it.
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                model.banner = "Could not read \(url.lastPathComponent)."
                return
            }
            switch TextFileImport.text(from: data, type: type) {
            case .success(let text):
                model.save(text, origin: .drop, title: TextFileImport.title(forFileNamed: url.lastPathComponent))
            case .failure(.notText):
                model.banner = "\(url.lastPathComponent) is not a text file."
            case .failure(.tooLarge(let bytes)):
                model.banner = "\(url.lastPathComponent) is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); the limit is 5 MB."
            case .failure(.unreadable):
                model.banner = "Could not read \(url.lastPathComponent) as text."
            }
        } else if let text = await load(String.self, from: provider), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.save(text, origin: .drop)
        }
    }

    private static func load<T: Transferable & Sendable>(_ type: T.Type, from provider: NSItemProvider) async -> T? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: type) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }
}
