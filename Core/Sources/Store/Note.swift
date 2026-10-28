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

extension Note: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "note"
}

extension Date {
    /// Whole milliseconds, which is what GRDB's `.datetime` text keeps.
    var storedPrecision: Date {
        Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate * 1000).rounded(.down) / 1000)
    }
}
