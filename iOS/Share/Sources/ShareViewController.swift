import BoopstashCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share ▸ BoopStash (#66): saves what is shared as a note and closes. It
/// only writes: titles come from the rules, text in images is read and
/// sync happens when the app next runs.
final class ShareViewController: UIViewController {
    private let status = ShareStatus()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(status: status))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await save() }
    }

    private func save() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let message: String
        do {
            message = try await ShareSaver.save(providers)
        } catch {
            message = error.localizedDescription
        }
        status.message = message
        try? await Task.sleep(for: .seconds(1))
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
@Observable
final class ShareStatus {
    var message: String?
}

struct ShareView: View {
    let status: ShareStatus

    var body: some View {
        VStack(spacing: 12) {
            if let message = status.message {
                Text(message).multilineTextAlignment(.center)
            } else {
                ProgressView("Saving to BoopStash…")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
enum ShareSaver {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// Reads text, links and images from the providers and saves one note.
    static func save(_ providers: [NSItemProvider]) async throws -> String {
        guard let folder = SharedStore.folder else { throw Failure(errorDescription: "BoopStash cannot reach its notes from here.") }
        // The app moves its store into the group on its first launch; until
        // then, writing here would start a second, empty one.
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(SharedStore.fileName).path) else {
            throw Failure(errorDescription: "Open BoopStash once, then share again.")
        }
        let store = try NoteStore.open(at: folder.appendingPathComponent(SharedStore.fileName), shared: true)
        var parts: [String] = []
        var images: [(Data, UTType)] = []
        // What could not be kept, said rather than dropped in silence.
        var skipped: [String] = []
        for provider in providers {
            // Core's rules for images, as on the Mac: the supported types,
            // the size limit, and content that matches its type.
            if let type = ImageImport.preferredType(among: provider.registeredTypeIdentifiers) {
                do {
                    let data = try await provider.loadData(for: type)
                    switch ImageImport.check(data, type: type) {
                    case .success(let checked): images.append((data, checked))
                    case .failure(let refusal): skipped.append(ImageImport.message(for: refusal, name: provider.suggestedName))
                    }
                } catch {
                    skipped.append("An image could not be read.")
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                do { parts.append(try await provider.loadObject(ofClass: URL.self).absoluteString) } catch { skipped.append("A link could not be read.") }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                do { parts.append(try await provider.loadObject(ofClass: String.self)) } catch { skipped.append("Some text could not be read.") }
            } else {
                skipped.append("Something shared is not text, a link or an image.")
            }
        }
        var note = Note(body: "", createdAt: Date())
        // The images and the note go in together: if anything fails, the
        // images already stored go again, so nothing half-saved is left
        // behind to sync.
        var stored: [UUID] = []
        do {
            for (data, type) in images {
                let attachment = try store.addAttachment(data, contentType: type.identifier, noteID: note.id)
                stored.append(attachment.id)
                parts.append(AttachmentReference.markdown(for: attachment.id))
            }
            let body = parts.joined(separator: "\n\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(errorDescription: (["Nothing BoopStash can keep was shared."] + skipped).joined(separator: "\n"))
            }
            note.body = body
            note.title = RuleTitler.title(for: body, kind: ContentKind.detect(body))
            try store.save(note)
        } catch {
            for id in stored { try? store.deleteAttachment(id: id) }
            throw error
        }
        return (["Saved to BoopStash."] + skipped.map { "Not kept: \($0)" }).joined(separator: "\n")
    }
}

@MainActor
private extension NSItemProvider {
    func loadData(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    func loadObject<T: _ObjectiveCBridgeable & Sendable>(ofClass: T.Type) async throws -> T where T._ObjectiveCType: NSItemProviderReading {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: T.self) { value, error in
                if let value { continuation.resume(returning: value) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
