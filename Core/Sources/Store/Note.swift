import CryptoKit
import Foundation
import GRDB

/// One stashed buffer. The body is markdown source (ADR 0002); attachments are
/// referenced from it by ID and stored separately (milestone 4).
public struct Note: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// A title the user typed is never replaced by a generated one.
    public var titleIsUserSet: Bool
    public var body: String
    /// Dates are kept to the millisecond, the precision the database stores,
    /// so a note compares equal to itself after a round trip.
    public var createdAt: Date { didSet { createdAt = createdAt.storedPrecision } }
    public var updatedAt: Date { didSet { updatedAt = updatedAt.storedPrecision } }
    /// The frontmost app when the note was captured, for recall ("the thing I
    /// copied from Safari"). Nil for notes typed in Boopstash itself.
    public var sourceBundleID: String?
    public var sourceAppName: String?
    /// `contentHash` of the body the on-device model last titled, so an
    /// unchanged note is not sent to the model again, across launches too.
    public var modelTitledHash: String?
    /// The highlighting override (`SyntaxChoice.stored`); nil detects.
    public var syntaxOverride: String?

    public init(
        id: UUID = UUID(),
        title: String = "",
        titleIsUserSet: Bool = false,
        body: String,
        createdAt: Date,
        updatedAt: Date? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.titleIsUserSet = titleIsUserSet
        self.body = body
        self.createdAt = createdAt.storedPrecision
        self.updatedAt = (updatedAt ?? createdAt).storedPrecision
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
    }
}

extension Note {
    /// A stable digest of the body (SHA-256, hex), for "has this text changed
    /// since we last looked". Stable across launches, unlike `hashValue`.
    public static func contentHash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var syntaxChoice: SyntaxChoice {
        get { SyntaxChoice(stored: syntaxOverride) }
        set { syntaxOverride = newValue.stored }
    }

    /// Whether the current title is the model's title for the current body.
    public var hasCurrentModelTitle: Bool {
        modelTitledHash == Note.contentHash(body)
    }
}

extension Note: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "note"
}

extension Date {
    /// Whole milliseconds, which is what GRDB's `.datetime` text keeps.
    var storedPrecision: Date {
        Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate * 1000).rounded(.down) / 1000)
    }
}
