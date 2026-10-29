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
  data-ownership cost of option A. Each file carries YAML front matter (title,
  created, updated, source app, ID) above the body. Writing it is the one use
  of the `files.user-selected.read-write` entitlement: the app can write only
  where the user points it in an open panel.
- **The schema lives in `BoopstashCore`** with migrations and tests; only a thin
  `Live*` adapter imports CloudKit.

## End-to-end encryption (resolved 2026-10-28)

The open question was whether CloudKit's encrypted fields are end-to-end
encrypted without Advanced Data Protection, and how assets are protected.
Apple's current documentation answers both:

- **Encrypted fields are encrypted on the device** with key material in the
  user's iCloud Keychain, and decrypted only after fetching
  ([`CKRecord.encryptedValues`](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues),
  [Encrypting user data](https://developer.apple.com/documentation/cloudkit/encrypting-user-data)).
- **They are end-to-end encrypted only with Advanced Data Protection.** The
  `encryptedValues` documentation: "When you enable Advanced Data Protection,
  the encryption keys are available exclusively to the record's owner and, if
  the user shares the record, that share's participants." Apple's Platform
  Security guide ([Advanced Data Protection for iCloud](https://support.apple.com/guide/security/sec973254c5f/web))
  explains why. Under standard protection, CloudKit service keys are also
  held in Apple's hardware security modules. Turning ADP on deletes them
  there, and then "protects CloudKit fields that third-party developers
  choose to mark as encrypted, and all CloudKit assets."
- **Assets get the same protection as encrypted fields, not less.** CloudKit
  encrypts an asset in chunks and keeps the asset key in an encrypted field
  of its record, "so CloudKit ultimately encrypts the asset data to a key in
  the user's iCloud Keychain."

So: **with Advanced Data Protection, everything BoopStash syncs is end-to-end
encrypted; without it, it is encrypted with keys Apple can use**, as for most
iCloud data. The README says this plainly and suggests turning ADP on.

Decisions that follow:

- **Every field the app defines goes in `encryptedValues`.** That covers
  title, body, dates, source app, recognised image text, the title flags and
  the syntax override. `CKSyncEngine` needs no server-side queries, so nothing
  needs an index. Left in the clear are only what CloudKit itself requires:
  record names (random UUIDs), record types, the zone, and `CKRecord.Reference`s
  from attachments to their notes, which CloudKit cannot encrypt.
- **Fields are encrypted from the first schema.** CloudKit cannot convert an
  existing plain field to an encrypted one, so the first schema deployed to
  Production must already be encrypted.
- **A reset iCloud Keychain loses the synced copy, not the notes.** When
  CloudKit reports it can no longer decrypt (`CKError.zoneNotFound` with
  `CKErrorUserDidResetEncryptedDataKey` in `userInfo`), the app deletes and
  recreates its zone and uploads everything from the local store again. The
  local SQLite store stays the source of truth.

## Consequences

- Search and the date filter are SQL queries, not a crawl over files.
- Users who want plain files get them through export, not as the live store.
- A schema change is a migration in Core plus a CloudKit schema change, which
  must be deployed to production in the CloudKit console before a release that
  depends on it.
