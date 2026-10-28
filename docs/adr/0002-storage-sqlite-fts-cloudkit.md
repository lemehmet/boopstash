# ADR 0002 — Storage: SQLite with full-text search, synced through CloudKit

- **Status:** Accepted (2026-10-28)
- **Deciders:** boopstash maintainers

## Context

Notes must be searchable by title and content, filterable by age ("last N
days"), able to hold images, and shared between a Mac and an iPhone through the
user's iCloud without passing through any other server.

Two shapes were considered:

| | A: SQLite + FTS5 + CloudKit | B: markdown files in iCloud Drive |
|---|---|---|
| Search | FTS5, in the store | Needs a separate index anyway |
| Sync | Record-level, conflicts under our control | iCloud Drive conflict copies; eviction and re-download on iOS |
| Data ownership | Opaque without export | Plain files, grep-able |
| Images | CloudKit assets | Files next to the note |

SwiftData with CloudKit was ruled out: it hides the sync engine, constrains the
schema (no unique constraints, every attribute optional) and gives no control
over conflict resolution or what is encrypted.

## Decision

- **Local store: SQLite via [GRDB](https://github.com/groue/GRDB.swift)**, one
  database in the app container. FTS5 indexes title, body, recognised image text
  and source-app name.
- **Note body is markdown text.** Images are attachments stored beside the
  database and referenced from the body by ID (`![](attachment:<uuid>)`), so the
  body stays portable and the editor never holds binary data.
- **Sync: `CKSyncEngine`** against the private database of the app's iCloud
  container. Notes are records; attachments are `CKAsset`s. Sync is optional and
  the app is fully functional without an iCloud account.
- **Export is a first-class feature, not an afterthought.** "Export as a folder
  of `.md` files plus attachments" ships with the Mac MVP, which answers the
  data-ownership cost of option A.
- **The schema lives in `BoopstashCore`** with migrations and tests; only a thin
  `Live*` adapter imports CloudKit.

## Open question — end-to-end encryption

CloudKit offers field-level `encryptedValues` on `CKRecord`, which we believe
are end-to-end encrypted with keys held in the user's iCloud Keychain whether or
not Advanced Data Protection is on. That must be confirmed against Apple's
current documentation before the sync milestone, along with how `CKAsset`
contents are protected. The intent: note title, body and metadata go in
`encryptedValues`; if assets are only end-to-end under Advanced Data Protection,
the README says so plainly.

## Consequences

- Search and the date filter are SQL queries, not a crawl over files.
- Users who want plain files get them through export, not as the live store.
- A schema change is a migration in Core plus a CloudKit schema change, which
  must be deployed to production in the CloudKit console before a release that
  depends on it.
