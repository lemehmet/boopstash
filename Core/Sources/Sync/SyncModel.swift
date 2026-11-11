import CryptoKit
import Foundation

/// What iCloud sync exchanges (#63), free of CloudKit so it can be tested:
/// the `LiveSyncEngine` adapter turns these into `CKRecord`s and back. Every
/// field the app defines travels in `encrypted`, which the adapter writes to
/// `encryptedValues` (ADR 0002); in the clear are only the record name (a
/// random UUID), the type, the parent reference and the asset. Labels add
/// nothing in the clear (ADR 0011).
public struct SyncRecord: Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case note = "Note"
        case attachment = "Attachment"
        /// A label of the catalog (ADR 0011).
        case label = "Label"
    }

    public var kind: Kind
    /// The record name: the note's, attachment's or label's ID, lowercased.
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

extension SyncRecord {
    /// A digest of every field but the dates, which do not come back from
    /// the server exactly as sent: the same for a record this device built
    /// and that record coming back, different once another device changed
    /// its text, title, settings or labels (#229).
    public var contentDigest: String {
        let parts: [[String]] = encrypted.keys.sorted().compactMap { key in
            switch encrypted[key] {
            case .string(let value)?: [key, "s", value]
            case .bool(let value)?: [key, "b", value ? "1" : "0"]
            case .int(let value)?: [key, "i", String(value)]
            case .strings(let values)?: [key, "l"] + values.sorted()
            case .date?, nil: nil
            }
        }
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SyncValue: Equatable, Sendable {
    case string(String)
    case date(Date)
    case bool(Bool)
    case int(Int)
    /// A string list, such as a note's label IDs (ADR 0011).
    case strings([String])

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var date: Date? { if case .date(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var int: Int? { if case .int(let value) = self { value } else { nil } }
    var strings: [String]? { if case .strings(let value) = self { value } else { nil } }
}

/// Every record waiting to be sent, by name.
public struct SyncPending: Equatable, Sendable {
    public struct Name: Hashable, Sendable {
        public var kind: SyncRecord.Kind
        public var name: String
    }

    public var saves: [Name] = []
    public var deletes: [Name] = []
}

/// A local change waiting to be sent.
public enum SyncChange: Equatable, Sendable {
    /// `version` is the row's pending version when the record was built;
    /// acknowledging it clears the row only if nothing changed since.
    case save(SyncRecord, systemFields: Data?, version: Int)
    case delete(kind: SyncRecord.Kind, name: String, systemFields: Data?)
}

public enum SyncMapping {
    /// The fields that are booleans; CloudKit hands every number back as
    /// one type, so reading a record needs to know.
    public static let booleanFields: Set<String> = ["titleIsUserSet"]

    /// The one declaration of what each record type carries: every field
    /// is written from here, and the schema is read from here, so a field
    /// cannot be sent without being in the schema. Production accepts only
    /// deployed fields: one added here must also be set in
    /// `DemoNotes.schemaSeedStore()` (a test checks), synced from a
    /// development build, and deployed (CONTRIBUTING ▸ iCloud schema).
    static let noteFields: [(name: String, value: @Sendable (Note) -> SyncValue?)] = [
        ("title", { .string($0.title) }),
        ("titleIsUserSet", { .bool($0.titleIsUserSet) }),
        ("body", { .string($0.body) }),
        ("createdAt", { .date($0.createdAt) }),
        ("updatedAt", { .date($0.updatedAt) }),
        ("sourceBundleID", { $0.sourceBundleID.map(SyncValue.string) }),
        ("sourceAppName", { $0.sourceAppName.map(SyncValue.string) }),
        ("modelTitledHash", { $0.modelTitledHash.map(SyncValue.string) }),
        ("syntaxOverride", { $0.syntaxOverride.map(SyncValue.string) }),
    ]

    /// A note's labels travel as a list of label IDs, never names (ADR
    /// 0011); absent when it has none, so clearing them clears the field.
    static let labelIDsField = "labelIDs"

    static let labelFields: [(name: String, value: @Sendable (NoteLabel) -> SyncValue?)] = [
        ("name", { .string($0.name) }),
        ("color", { .string($0.color) }),
        ("details", { .string($0.details) }),
        ("createdAt", { .date($0.createdAt) }),
        ("updatedAt", { .date($0.updatedAt) }),
    ]

    static let attachmentFields: [(name: String, value: @Sendable (NoteAttachment) -> SyncValue?)] = [
        ("contentType", { .string($0.contentType) }),
        ("byteSize", { .int($0.byteSize) }),
        ("createdAt", { .date($0.createdAt) }),
        ("recognizedText", { $0.recognizedText.map(SyncValue.string) }),
    ]

    /// Every encrypted field each record type can carry: the CloudKit schema.
    public static let schemaFields: [SyncRecord.Kind: Set<String>] = [
        .note: Set(noteFields.map(\.name) + [labelIDsField]),
        .attachment: Set(attachmentFields.map(\.name)),
        .label: Set(labelFields.map(\.name)),
    ]

    /// `labelIDs`: the labels the note carries, sent sorted so the same set
    /// is always the same record.
    public static func record(for note: Note, labelIDs: Set<UUID> = []) -> SyncRecord {
        var fields = Dictionary(uniqueKeysWithValues: noteFields.compactMap { field in field.value(note).map { (field.name, $0) } })
        if !labelIDs.isEmpty {
            fields[labelIDsField] = .strings(labelIDs.map { $0.uuidString.lowercased() }.sorted())
        }
        return SyncRecord(kind: .note, name: note.id.uuidString.lowercased(), encrypted: fields)
    }

    /// The label IDs a note record carries; none when the field is absent
    /// (no labels, or a record from before labels). Entries that are not
    /// IDs are skipped.
    public static func labelIDs(from record: SyncRecord) -> Set<UUID> {
        Set((record.encrypted[labelIDsField]?.strings ?? []).compactMap(UUID.init(uuidString:)))
    }

    public static func record(for label: NoteLabel) -> SyncRecord {
        let fields = Dictionary(uniqueKeysWithValues: labelFields.compactMap { field in field.value(label).map { (field.name, $0) } })
        return SyncRecord(kind: .label, name: label.id.uuidString.lowercased(), encrypted: fields)
    }

    /// Nil when the record is not a usable label. The name is trimmed; a
    /// colour this app cannot read becomes the palette's first.
    public static func label(from record: SyncRecord) -> NoteLabel? {
        let fields = record.encrypted
        guard record.kind == .label, let id = UUID(uuidString: record.name),
              let name = fields["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let createdAt = fields["createdAt"]?.date
        else { return nil }
        return NoteLabel(id: id, name: name, color: fields["color"]?.string.flatMap(LabelColor.parse) ?? LabelColor.palette[0],
                         details: fields["details"]?.string ?? "", createdAt: createdAt,
                         updatedAt: fields["updatedAt"]?.date ?? createdAt)
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
        let fields = Dictionary(uniqueKeysWithValues: attachmentFields.compactMap { field in field.value(attachment).map { (field.name, $0) } })
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
        /// The labels the note carries here: both sides' (ADR 0011).
        public var labelIDs: Set<UUID> = []
    }

    /// `local` has unsent changes. Field by field: a body changed on both
    /// sides keeps the server's and saves this device's as a copy; a title
    /// the user set beats a generated one, and between two the newer wins;
    /// other settings follow the newer edit. Labels merge by union: one
    /// added on either side stays, so a removal made while the other side
    /// also changed the note can come back (ADR 0011).
    public static func merge(local: Note, server: Note, localLabels: Set<UUID> = [], serverLabels: Set<UUID> = [],
                             now: Date = Date()) -> Outcome {
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
        let labels = localLabels.union(serverLabels)
        return Outcome(note: merged, conflictCopy: copy,
                       stillPending: SyncMapping.record(for: merged, labelIDs: labels) != SyncMapping.record(for: server, labelIDs: serverLabels),
                       labelIDs: labels)
    }
}
