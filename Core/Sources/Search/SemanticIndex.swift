import Foundation
import GRDB

/// A sentence embedding, unit length, so similarity is a dot product.
/// Nil is a failure (the model would not load or run): nothing is stored
/// and the note is tried again later. Empty means the text has nothing to
/// embed.
public typealias Embedder = @Sendable (String) async -> [Float]?

/// On-device semantic search (#157): every note has a sentence embedding of
/// its title, text and image text, kept beside it and rebuilt here, never
/// synced. Search ranks by similarity to the query's embedding; the model
/// (all-MiniLM-L6-v2) is the app's, given as an `Embedder`.
extension NoteStore {
    /// Below this, a note is not similar enough to show: related text
    /// scores about 0.2 to 0.5 with this model, unrelated under 0.15.
    public static let similarityThreshold: Float = 0.2

    /// What a note's embedding is made from: its title, its text without
    /// image references, and its images' text. The model reads the first
    /// 128 pieces, so the start of a note counts most.
    public static func embeddingText(title: String, body: String, imageText: String?) -> String {
        [title, AttachmentReference.removingReferences(from: body), imageText ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static let awaitingEmbeddingSQL = """
        FROM note LEFT JOIN noteEmbedding ON noteEmbedding.noteID = note.id
        WHERE noteEmbedding.noteID IS NULL
        """

    /// Notes without a current embedding, newest first, at most `limit`,
    /// with the text to embed and its hash.
    public func notesAwaitingEmbedding(limit: Int = 32) throws -> [(id: UUID, text: String, hash: String)] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT note.id, note.title, note.body, note.imageText \(Self.awaitingEmbeddingSQL) ORDER BY note.updatedAt DESC LIMIT ?",
                             arguments: [limit]).map { row in
                let text = Self.embeddingText(title: row["title"], body: row["body"], imageText: row["imageText"])
                return (row["id"], text, Note.contentHash(text))
            }
        }
    }

    /// How many notes await embedding, re-delivered as that changes; the
    /// app runs the worker while it is above zero.
    public func pendingEmbeddings() -> AsyncThrowingStream<Int, any Error> {
        let values = ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) \(Self.awaitingEmbeddingSQL)") ?? 0
        }.removeDuplicates().values(in: writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await count in values { continuation.yield(count) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stores a note's embedding, made from text with `sourceHash`, unless
    /// the note has changed since (its text no longer has that hash).
    public func setEmbedding(_ vector: [Float], for noteID: UUID, sourceHash: String) throws {
        try writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT title, body, imageText FROM note WHERE id = ?", arguments: [noteID]),
                  Note.contentHash(Self.embeddingText(title: row["title"], body: row["body"], imageText: row["imageText"])) == sourceHash
            else { return }
            try db.execute(sql: "INSERT OR REPLACE INTO noteEmbedding (noteID, vector) VALUES (?, ?)",
                           arguments: [noteID, Self.data(vector)])
        }
    }

    /// Embeds every note that needs it, newest first, until none is left,
    /// the task is cancelled, or the embedder fails (then the rest wait for
    /// the next run). Run it off the main actor.
    public func embedPendingNotes(with embed: Embedder) async {
        var failed: Set<UUID> = []
        while !Task.isCancelled, let batch = try? notesAwaitingEmbedding(limit: 32 + failed.count) {
            let todo = batch.filter { !failed.contains($0.id) }
            guard !todo.isEmpty else { return }
            for item in todo {
                if Task.isCancelled { return }
                guard let vector = await embed(item.text) else {
                    // The model failed: not recorded, so tried again later.
                    failed.insert(item.id)
                    if failed.count >= 3 { return }
                    continue
                }
                do { try setEmbedding(vector, for: item.id, sourceHash: item.hash) } catch { return }
            }
        }
    }

    /// Notes similar to `vector`, most similar first, within `query`'s age
    /// limit and labels, leaving out `excluding` (already shown), at least
    /// `threshold` similar.
    public func notesSimilar(to vector: [Float], within query: NoteQuery = NoteQuery(), excluding: Set<UUID> = [],
                             threshold: Float = similarityThreshold, limit: Int = 20,
                             now: Date = Date(), calendar: Calendar = .current) throws -> [(note: Note, score: Float)] {
        guard !vector.isEmpty else { return [] }
        let cutoff = query.cutoff(now: now, calendar: calendar)
        return try writer.read { db in
            var sql = "SELECT note.id AS noteID, noteEmbedding.vector FROM noteEmbedding JOIN note ON note.id = noteEmbedding.noteID"
            var conditions: [String] = []
            var values: [any DatabaseValueConvertible] = []
            if let cutoff {
                conditions.append("note.updatedAt >= ?")
                values.append(cutoff)
            }
            if let (condition, labelValues) = Self.labelCondition(query.labels) {
                conditions.append(condition)
                values.append(contentsOf: labelValues)
            }
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            let arguments: StatementArguments = StatementArguments(values)
            var scored: [(UUID, Float)] = []
            for (index, row) in try Row.fetchAll(db, sql: sql, arguments: arguments).enumerated() {
                // A superseded search stops (#165).
                if index % 256 == 0, Task.isCancelled { return [] }
                let id: UUID = row["noteID"]
                guard !excluding.contains(id) else { continue }
                let candidate = Self.vector(row["vector"])
                guard candidate.count == vector.count else { continue }
                let score = zip(candidate, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                if score >= threshold { scored.append((id, score)) }
            }
            scored.sort { $0.1 > $1.1 }
            return try scored.prefix(limit).compactMap { id, score in
                try Note.fetchOne(db, key: id).map { ($0, score) }
            }
        }
    }

    /// A note's own embedding, for "similar notes"; nil until it has one.
    public func embedding(of noteID: UUID) throws -> [Float]? {
        try writer.read { db in
            try Data.fetchOne(db, sql: "SELECT vector FROM noteEmbedding WHERE noteID = ?", arguments: [noteID]).map(Self.vector)
        }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
