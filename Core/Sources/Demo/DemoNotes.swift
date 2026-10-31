#if DEBUG
import Foundation

/// Made-up notes for App Store screenshots (#69), in debug builds only.
/// Nothing here is anyone's real data: the hosts are example.com, the keys
/// and IDs are invented.
public enum DemoNotes {
    /// An in-memory store holding the demo notes.
    public static func store(now: Date = Date()) throws -> NoteStore {
        let store = try NoteStore.inMemory()
        // A few labels, so the screenshots show chips (#184).
        var labelIDs: [String: UUID] = [:]
        for (name, color) in labels {
            labelIDs[name] = try store.createLabel(name: name, color: color, now: now.addingTimeInterval(-30 * day)).id
        }
        for (index, demo) in notes.enumerated() {
            let date = now.addingTimeInterval(-demo.age - Double(index) * 60)
            var note = Note(title: demo.title ?? "", titleIsUserSet: demo.title != nil, body: demo.body,
                            createdAt: date, updatedAt: date, sourceAppName: demo.source)
            if demo.title == nil { note.title = RuleTitler.title(for: demo.body, kind: ContentKind.detect(demo.body)) }
            try store.save(note)
            for name in demo.labels {
                guard let id = labelIDs[name] else { continue }
                try store.assignLabel(id, to: note.id)
            }
        }
        return store
    }

    static let labels: [(name: String, color: String)] = [
        ("api", "#1d76db"), (ProblemReport.labelName, ProblemReport.labelColor), ("needs review", "#fbca04"), ("release", "#0e8a16"),
    ]

    /// One note, one image and one label with every field the sync records
    /// can carry set, in an in-memory store: syncing it from a development build
    /// creates the complete CloudKit schema in the Development environment,
    /// to be deployed to Production (see CONTRIBUTING ▸ iCloud schema).
    /// Made-up content, like the rest.
    public static func schemaSeedStore() throws -> NoteStore {
        let store = try NoteStore.inMemory()
        var note = Note(title: "Schema seed", titleIsUserSet: true, body: "", createdAt: Date(),
                        sourceBundleID: "com.example.seed", sourceAppName: "Seed")
        note.syntaxOverride = "json"
        // A 1 x 1 PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==")!
        let image = try store.addAttachment(png, contentType: "public.png", noteID: note.id)
        try store.setRecognizedText("seed", for: image.id)
        note.body = "Every synced field, set. " + AttachmentReference.markdown(for: image.id)
        note.modelTitledHash = Note.contentHash(note.body)
        try store.save(note)
        let label = try store.createLabel(name: "Seed", color: "#1d76db", details: "Every label field, set.")
        try store.assignLabel(label.id, to: note.id)
        return store
    }

    struct Demo {
        var title: String?
        var body: String
        var age: TimeInterval
        var source: String?
        var labels: [String] = []
    }

    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86400

    static let notes: [Demo] = [
        Demo(title: "Order service response", body: """
            {
              "order": {
                "id": "ord_7Q2K9X",
                "status": "shipped",
                "items": [
                  { "sku": "MUG-BLUE-12", "quantity": 2, "price": 14.5 },
                  { "sku": "TEA-SENCHA-100", "quantity": 1, "price": 9.25 }
                ],
                "shipping": { "carrier": "Example Post", "eta": "2026-11-03" }
              }
            }
            """, age: 0.2 * hour, source: "Terminal", labels: ["api"]),
        Demo(title: "Weekly signups by region", body: """
            SELECT region,
                   date_trunc('week', created_at) AS week,
                   count(*) AS signups
            FROM accounts
            WHERE created_at >= now() - interval '90 days'
            GROUP BY region, week
            ORDER BY week DESC, signups DESC;
            """, age: 3 * hour, source: "Safari"),
        Demo(title: "Release checklist", body: """
            # Release 2.4

            - [x] Update the changelog
            - [x] Bump the version in the manifest
            - [ ] Run the migration on staging
            - [ ] Announce in the team channel

            > Tag only after staging is green.

            ```sh
            git tag v2.4.0 && git push origin v2.4.0
            ```
            """, age: 5 * hour, source: nil, labels: ["needs review", "release"]),
        Demo(title: nil, body: """
            2026-10-29T09:14:02Z INFO  api  request id=8f3a path=/v1/orders status=200 duration=41ms
            2026-10-29T09:14:03Z WARN  api  slow query id=8f3b table=line_items duration=1240ms
            2026-10-29T09:14:05Z ERROR api  upstream timeout id=8f3c host=payments.example.com attempt=2
            2026-10-29T09:14:07Z INFO  api  request id=8f3d path=/v1/orders status=200 duration=38ms
            """, age: 1 * day, source: "Console", labels: ["api", "bug"]),
        Demo(title: "Retry with backoff", body: """
            func retry<T>(times: Int = 3, _ work: () async throws -> T) async throws -> T {
                var delay: Duration = .milliseconds(200)
                for _ in 1..<times {
                    if let value = try? await work() { return value }
                    try await Task.sleep(for: delay)
                    delay *= 2
                }
                return try await work()
            }
            """, age: 2 * day, source: "Xcode", labels: ["needs review"]),
        Demo(title: "Staging config", body: """
            service:
              name: orders
              replicas: 3
              env:
                LOG_LEVEL: info
                DATABASE_URL: postgres://orders@db.staging.example.com/orders
            """, age: 4 * day, source: "Terminal"),
        Demo(title: nil, body: "https://docs.example.com/guides/rate-limits#burst", age: 6 * day, source: "Safari"),
        Demo(title: "Meeting notes", body: """
            Design review

            Agreed to ship the new onboarding behind a flag first, then widen it once the
            completion rate holds for a week. Open question: keep the email step optional?
            """, age: 12 * day, source: "Notes"),
    ]
}
#endif
