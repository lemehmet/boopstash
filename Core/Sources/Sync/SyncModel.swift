import Foundation

/// What iCloud sync exchanges (#63), free of CloudKit so it can be tested:
/// the `LiveSyncEngine` adapter turns these into `CKRecord`s and back. Every
/// field the app defines travels in `encrypted`, which the adapter writes to
/// `encryptedValues` (ADR 0002); in the clear are only the record name (a
/// random UUID), the type, the parent reference and the asset.
public struct SyncRecord: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case note = "Note"
        case attachment = "Attachment"
    }

    public var kind: Kind
    /// The record name: the note's or attachment's ID, lowercased.
    public var name: String
    public var encrypted: [String: SyncValue]
    /// An attachment's note, as a `CKRecord.Reference`, which CloudKit
    /// cannot encrypt.
    public var parent: String?
    /// An attachment's file, uploaded as its `CKAsset`.
    public var assetFile: URL?

    public init(kind: Kind, name: String, encrypted: [String: SyncValue], parent: String? = nil, assetFile: URL? = nil) {
        self.kind = kind
        self.name = name
        self.encrypted = encrypted
        self.parent = parent
        self.assetFile = assetFile
    }
}

public enum SyncValue: Equatable, Sendable {
    case string(String)
    case date(Date)
    case bool(Bool)
    case int(Int)

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var date: Date? { if case .date(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var int: Int? { if case .int(let value) = self { value } else { nil } }
}

/// A local change waiting to be sent.
public enum SyncChange: Equatable, Sendable {
    /// `version` is the row's pending version when the record was built;
    /// acknowledging it clears the row only if nothing changed since.
    case save(SyncRecord, systemFields: Data?, version: Int)
    case delete(kind: SyncRecord.Kind, name: String, systemFields: Data?)
}

public enum SyncMapping {
    public static func record(for note: Note) -> SyncRecord {
        var fields: [String: SyncValue] = [
            "title": .string(note.title),
            "titleIsUserSet": .bool(note.titleIsUserSet),
            "body": .string(note.body),
            "createdAt": .date(note.createdAt),
            "updatedAt": .date(note.updatedAt),
        ]
        if let value = note.sourceBundleID { fields["sourceBundleID"] = .string(value) }
        if let value = note.sourceAppName { fields["sourceAppName"] = .string(value) }
        if let value = note.modelTitledHash { fields["modelTitledHash"] = .string(value) }
        if let value = note.syntaxOverride { fields["syntaxOverride"] = .string(value) }
        return SyncRecord(kind: .note, name: note.id.uuidString.lowercased(), encrypted: fields)
    }

    /// Nil when the record is not a usable note (a newer app's record with
    /// fields this one cannot read, say).
    public static func note(from record: SyncRecord) -> Note? {
        let fields = record.encrypted
        guard record.kind == .note, let id = UUID(uuidString: record.name),
              let body = fields["body"]?.string, let createdAt = fields["createdAt"]?.date
        else { return nil }
        var note = Note(id: id, title: fields["title"]?.string ?? "", titleIsUserSet: fields["titleIsUserSet"]?.bool ?? false,
                        body: body, createdAt: createdAt, updatedAt: fields["updatedAt"]?.date ?? createdAt,
                        sourceBundleID: fields["sourceBundleID"]?.string, sourceAppName: fields["sourceAppName"]?.string)
        note.modelTitledHash = fields["modelTitledHash"]?.string
        note.syntaxOverride = fields["syntaxOverride"]?.string
        return note
    }

    public static func record(for attachment: NoteAttachment, file: URL) -> SyncRecord {
        var fields: [String: SyncValue] = [
            "contentType": .string(attachment.contentType),
            "byteSize": .int(attachment.byteSize),
            "createdAt": .date(attachment.createdAt),
        ]
        if let text = attachment.recognizedText { fields["recognizedText"] = .string(text) }
        return SyncRecord(kind: .attachment, name: attachment.id.uuidString.lowercased(), encrypted: fields,
                          parent: attachment.noteID?.uuidString.lowercased(), assetFile: file)
    }

    public static func attachment(from record: SyncRecord) -> NoteAttachment? {
        let fields = record.encrypted
        guard record.kind == .attachment, let id = UUID(uuidString: record.name),
              let contentType = fields["contentType"]?.string, let byteSize = fields["byteSize"]?.int
        else { return nil }
        return NoteAttachment(id: id, noteID: record.parent.flatMap(UUID.init(uuidString:)), contentType: contentType,
                              byteSize: byteSize, createdAt: fields["createdAt"]?.date ?? Date(),
                              recognizedText: fields["recognizedText"]?.string)
    }
}

/// Merging a note changed on this device with the server's version of it.
public enum SyncMerge {
    public struct Outcome: Equatable, Sendable {
        /// What the note becomes here.
        public var note: Note
        /// This device's text, kept as a new note when both sides changed
        /// the body, so nothing is lost silently.
        public var conflictCopy: Note?
        /// Whether the merged note still differs from the server's and must
        /// be sent.
        public var stillPending: Bool
    }

    /// `local` has unsent changes. Field by field: a body changed on both
    /// sides keeps the server's and saves this device's as a copy; a title
    /// the user set beats a generated one, and between two the newer wins;
    /// other settings follow the newer edit.
    public static func merge(local: Note, server: Note, now: Date = Date()) -> Outcome {
        var merged = server
        var copy: Note?
        if local.body != server.body {
            var conflict = Note(title: "\(local.title.isEmpty ? "Untitled" : local.title) (conflict)", titleIsUserSet: true,
                                body: local.body, createdAt: now, updatedAt: now,
                                sourceBundleID: local.sourceBundleID, sourceAppName: local.sourceAppName)
            conflict.syntaxOverride = local.syntaxOverride
            copy = conflict
        }
        let localNewer = local.updatedAt > server.updatedAt
        switch (local.titleIsUserSet, server.titleIsUserSet) {
        case (true, false), (true, true) where localNewer:
            merged.title = local.title
            merged.titleIsUserSet = true
            merged.modelTitledHash = local.modelTitledHash
        default:
            break
        }
        if localNewer { merged.syntaxOverride = local.syntaxOverride }
        merged.updatedAt = max(local.updatedAt, server.updatedAt)
        return Outcome(note: merged, conflictCopy: copy, stillPending: SyncMapping.record(for: merged) != SyncMapping.record(for: server))
    }
}
