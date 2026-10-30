# ADR 0011 — Labels: one catalog, synced as its own record kind

- **Status:** Accepted (2026-10-30)
- **Deciders:** boopstash maintainers
- **Refines:** ADR 0002 (storage and sync)

## Context

Notes get labels, as GitHub issues do: each label has a name, a colour and a
description, and comes from one catalog shared by every note (#182). Both
the catalog and which notes carry which labels must sync between a user's
devices under ADR 0002's rules: every field the app defines is encrypted,
and only what CloudKit itself needs is in the clear.

Three shapes were considered:

| | A: names on the note | B: one record per assignment | C: a `Label` record kind, label IDs on the note |
|---|---|---|---|
| Rename or recolour | Rewrites every note that carries it | One record | One record |
| Colour and description | Need a catalog anyway | Need a catalog anyway | On the label |
| In the clear | Nothing new | A `CKRecord.Reference` to the note and to the label | Nothing new |
| Concurrent edits | Merge strings on the note | Two devices can create the same assignment twice | Union of two ID sets |
| Records per change | One note | One per label added or removed | One note |

A puts what is really one shared object on every note: renaming a label
touches every note carrying it, and two devices renaming it differently
leave notes disagreeing. B is the relational shape, but every assignment
becomes a record whose references CloudKit cannot encrypt (ADR 0002), it
multiplies the records to send, and adding the same label on two devices
needs its own deduplication.

## Decision

- **A third record kind, `Label`,** for the catalog: name, colour (`#rrggbb`),
  description, created and updated dates, all in `encryptedValues`. The
  record name is the label's random UUID.
- **A note carries its labels as `labelIDs`, an encrypted string list on the
  `Note` record.** IDs, never names; no `CKRecord.Reference`s. The field is
  absent when the note has no labels. Labels add nothing in the clear.
- **Locally**, a `label` table (with the sync columns the other kinds have)
  and a `noteLabel` table of note and label IDs, queryable in SQL. A
  `noteLabel` row has no foreign key to the label: CloudKit does not order a
  note after its labels, so a note may arrive first and must keep the ID.
- **Labelling a note does not change its `updatedAt`**, so it keeps its place
  in the list, but makes it pending: its record carries the IDs.
- **Names are unique regardless of case and kept trimmed.** The store keeps a
  case-folded `nameKey` with a unique index; SQLite's own `lower()` folds
  ASCII only.

### Merge rules

- **A note's labels merge by union**, in `SyncMerge` and in the App Group
  merge (`copyMissing`). A label added on either side stays. The cost: a
  label removed on one device while the other device also changed the note
  comes back. Losing a label someone added is worse than seeing one again.
- **The newer edit of a label wins** (`updatedAt`), as for a note's settings.
- **Two labels with the same name become one.** Two devices can each create
  "Bug" (or "bug") before syncing. Every device keeps the same one: the
  later `createdAt`, ties broken by the lower UUID. The notes carrying the
  other move to it and are sent again, and the other is deleted with a
  tombstone, so the deletion syncs. A device that receives the losing label
  folds it the same way, so the outcome does not depend on arrival order.
  The later, not the earlier: a label deleted and its name made again
  reaches another device as a new label and a deletion, in either order.
  Were the earlier kept, a device that got the new label first would fold
  it into the deleted one, and both would be gone. The later kept, the new
  label survives either way. The cost: such a device moves its notes from
  the deleted label to the new one, the union rule's trade again.
- **A label ID with no label in the catalog** (not arrived yet, or deleted)
  is ignored when reading and in the label filter, kept until its label
  arrives, and dropped by the next local save of the note.
- **Deleting a label** takes it off every note; the device that deleted it
  sends those notes again without it, and the other devices remove it from
  their notes when the deletion arrives.

### Older clients and clearing fields

- **0.4.1 leaves `labelIDs` alone.** It skips record types it does not know
  (`SyncRecord.Kind(rawValue:)` fails, the record is skipped), so `Label`
  records never reach it. It rebuilds a note's `CKRecord` from the system
  fields only and sets its own keys, and CloudKit sends only the keys set on
  a record, so an edit made in 0.4.1 leaves the server's `labelIDs` as it
  was. This follows from the code; the PR that adds labels records a manual
  check against Development.
- **The same mechanism means an absent field is never cleared by leaving it
  out.** A note whose last label is removed, sent as a record rebuilt from
  system fields without `labelIDs`, would keep its old labels on the server.
  So the adapter sets to nil every field of this app's schema
  (`SyncMapping.schemaFields`) that the record leaves out. Fields this app
  does not know are never touched, so a newer app's fields survive an edit
  here, as `labelIDs` survives 0.4.1. This also makes clearing other
  optional fields (the syntax override, say) reach the server.

## Consequences

- The CloudKit schema gains the `Label` record type and the note's
  `labelIDs` field. Production accepts only deployed fields, so both must be
  in `DemoNotes.schemaSeedStore()` (a test checks) and deployed before a
  release that writes them (CONTRIBUTING ▸ iCloud schema).
- Every place that assumed two record kinds handles three: tombstones,
  pending versions, resets, the App Group merge and the adapter. New kinds
  should follow the same path.
- Filtering by labels is SQL (`NoteQuery.labels`: a note matches only if it
  carries all of them), combined with the text, scope and age filters.
- Labels are listed by name; there is no hand ordering. Finding notes by
  label name from the search box is not part of this decision.
