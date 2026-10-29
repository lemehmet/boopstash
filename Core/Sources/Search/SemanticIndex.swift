import Foundation
import GRDB

/// A sentence embedding: unit length, so similarity is a dot product.
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

    /// Notes whose embedding is missing or was made from other text, at
    /// most `limit`, with the text to embed and its hash.
    public func notesAwaitingEmbedding(limit: Int = 32) throws -> [(id: UUID, text: String, hash: String)] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT note.id, note.title, note.body, note.imageText, noteEmbedding.sourceHash
                FROM note LEFT JOIN noteEmbedding ON noteEmbedding.noteID = note.id
                ORDER BY note.updatedAt DESC
                """)
            var pending: [(UUID, String, String)] = []
            for row in rows {
                let text = Self.embeddingText(title: row["title"], body: row["body"], imageText: row["imageText"])
                let hash = Note.contentHash(text)
                if (row["sourceHash"] as String?) != hash { pending.append((row["id"], text, hash)) }
                if pending.count >= limit { break }
            }
            return pending
        }
    }

    /// Stores a note's embedding, made from text with `hash`; nil records
    /// that this text has none.
    public func setEmbedding(_ vector: [Float]?, for noteID: UUID, sourceHash: String) throws {
        try writer.write { db in
            guard try Note.exists(db, key: noteID) else { return }
            try db.execute(sql: "INSERT OR REPLACE INTO noteEmbedding (noteID, sourceHash, vector) VALUES (?, ?, ?)",
                           arguments: [noteID, sourceHash, Self.data(vector ?? [])])
        }
    }

    /// Embeds every note that needs it, newest first, until none is left.
    /// Run it off the main actor.
    public func embedPendingNotes(with embed: Embedder) async {
        while let batch = try? notesAwaitingEmbedding(), !batch.isEmpty {
            for item in batch {
                if Task.isCancelled { return }
                let vector = await embed(item.text)
                do { try setEmbedding(vector, for: item.id, sourceHash: item.hash) } catch { return }
            }
        }
    }

    /// Notes similar to `vector`, most similar first, within `query`'s age
    /// limit, leaving out `excluding` (already shown), at least
    /// `threshold` similar.
    public func notesSimilar(to vector: [Float], within query: NoteQuery = NoteQuery(), excluding: Set<UUID> = [],
                             threshold: Float = similarityThreshold, limit: Int = 20,
                             now: Date = Date(), calendar: Calendar = .current) throws -> [(note: Note, score: Float)] {
        guard !vector.isEmpty else { return [] }
        let cutoff = query.cutoff(now: now, calendar: calendar)
        return try writer.read { db in
            var sql = "SELECT note.id AS noteID, noteEmbedding.vector FROM noteEmbedding JOIN note ON note.id = noteEmbedding.noteID"
            var arguments: StatementArguments = []
            if let cutoff {
                sql += " WHERE note.updatedAt >= ?"
                arguments += [cutoff]
            }
            var scored: [(UUID, Float)] = []
            for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
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
