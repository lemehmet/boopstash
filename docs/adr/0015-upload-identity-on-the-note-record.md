# ADR 0015 — A note record says which upload it is

- **Status:** Accepted (2026-11-25)
- **Deciders:** boopstash maintainers
- **Refines:** ADR 0002 (storage and sync) and ADR 0011 (labels: a save that keeps the edit date)

## Context

A device has to know its own note record when it comes back from iCloud.
When the server saved an upload but the answer was lost, and the note was
edited here again, the record that arrives is this device's own: the edit
here is newer and must be sent over it, with no merge and no "(conflict)"
copy (#229). Any other record is another device's save and is merged, the
text here kept as a copy when both changed it (`SyncMerge`).

Until now this was inferred. A record was this device's upload when its
content digest and its edit date (`updatedAt`) were those of a record
built here since the note was last in step (#229, #232, #233). The edit
date tells two saves with the same content apart only when the text was
edited in between. A save that is not an edit keeps `updatedAt`, so the
note keeps its place in the list: a label (ADR 0011), the syntax setting,
a generated title. So when another device made such a change and undid
it, the record that arrived equalled the upload in every field, the date
included, and was taken for it (#291). What the server held was then,
field for field, what this device had sent, so nothing was lost. It was
still a guess where there should be a fact, and every future field saved
without an edit date would have widened it.

Three shapes were considered for making it a fact:

| | A: a random value per record built | B: a device identifier and a counter | C: nothing in the record; remember the server's change tag |
|---|---|---|---|
| Tells an upload from another device's equal save | Yes | Yes | No: the tag of an upload whose answer was lost is never learned |
| What a reader of the decrypted record learns | That it was saved again | Which device saved it, and how many saves that device has made | Nothing |
| Stable across records | No | Yes, by design | — |
| Schema | One encrypted string on `Note` | One or two encrypted fields on `Note` | None |

C is what #215 already does, and it covers only acknowledged uploads. B
puts a stable name for a device into every note it saves; nothing here
needs to know *which* device, only *this one or not*.

## Decision

- **The `Note` record gains `uploadID`, an encrypted string.** The store
  gives each note record it builds for sending (`NoteStore.pendingSave`) a
  new random value: 122 random bits, written as a lowercased UUID string
  (`SyncMapping.newUploadID`). Nothing is derived from the note, the
  device, the account or the time.
- **It is in `encryptedValues` like every other field** (ADR 0002). Nothing
  new is in the clear, and the record name is unrelated to it.
- **What it reveals.** To someone who can decrypt the record (the user's
  devices, and Apple without Advanced Data Protection, as for every field):
  that the value changed means the record was built again, which the
  record's change tag and modification date, kept by CloudKit in the
  clear, already say. Values are not linked to each other, so they do not
  say which device saved a record or that two records came from the same
  one. It is not a device or user identifier and is not stable: a device
  never sends a value it received, and forgets its own once the note is in
  step.
- **Local only: the value is remembered in `syncUpload`** with the content
  digest and the edit date of the record it was given to, until the note
  is back in step (acknowledged, merged with a foreign record, deleted on
  the server, or sync reset), exactly as the digest and date were before.
  The same record built again, as when a send is retried, keeps the value
  it had, so a retry sends what was sent and the table holds one row per
  record that can be on the server, not one per attempt. A record that
  differs in content or edit date gets a new value.
- **The value is never logged and is not in the problem report.** The sync
  adapter logs record names and error descriptions, never field values;
  a note has no such field, so nothing made from a note (export, the
  problem report, the command line) can carry it. A device that applies a
  record does not store the value at all.
- **Only note records.** Label records take the newer edit and attachment
  records keep this device's until sent; neither asks "is this my
  upload?" by content, so neither has the gap, and neither gains a field.

### The identity is checked with the content and the date, not instead of them

A record coming back is this device's own upload only when **all three**
hold: it carries an `uploadID` remembered here for that note, its content
digest is the one that value was sent with, and its edit date is the one
it was sent with (within `NoteStore.uploadDateTolerance`, since dates are
rounded on the way). Anything else is foreign and is merged.

The identity cannot replace the other two, because of clients from before
it. Such a client rebuilds a `CKRecord` from the system fields and sets
only the keys of its own schema, and CloudKit sends only the keys set, so
its save leaves the server's `uploadID` where it is, exactly as 0.4.1
leaves `labelIDs` (ADR 0011). That is what "must not strip it" asks for,
and it means a value can outlive the upload it named:

1. This device uploads a note with value `T`; the answer is lost. The note
   is edited here again.
2. A device on an older version fetches the upload, changes the text (or a
   label, or the title) and saves. The server now holds its content, with
   `T` still on the record.
3. That record arrives here carrying `T`.

Were `T` alone the test, the edit here would be kept and sent over the
other device's change, with no merge and no copy: the failure this whole
mechanism exists to prevent, and worse than the gap being closed. With the
digest beside it, the record's content is not what `T` went up with, and
it is merged. With the date beside it, an older client that edits the
text and puts it back is merged too (#232).

So the three checks each close a different case:

| The record that arrives | Told apart by |
|---|---|
| Another device's edit | Content |
| A current client's save of the same content, edit date and all (a label, the syntax setting or a generated title changed and put back) | Identity |
| An older client's save that changed something, with this device's identity left on it | Content |
| An older client's edit of the text put back as it was, identity left on it | Edit date |
| No identity (an older client's save of a note no current client saved) | Identity: none is nobody's |

### What stays open

A client from before identities that makes a change which is not an edit
and undoes it, on a record carrying this device's identity, leaves a
record equal to the upload in every field. It passes for the upload.
Nothing in the record can tell the two apart, the server then holds
exactly what this device sent, and no data of either device is lost. The
case ends when no device runs a version from before this one. A test pins
it, so a change to it is a decision.

### Compatibility

- **A client from before the field** (up to 0.4.6) does not read
  `uploadID` and does not write it. A record it saves on a note that never
  had one has none; on a note a current client saved, the last value
  stays. Either way a current client treats the record by the rules
  above. The older client must not strip the field, and by the mechanism
  above it does not; the release gate checks this against Development.
- **A cost on 0.4.5 and 0.4.6.** Those versions recognise their own
  upload by a digest over every field of the record, known to them or not
  (#233 fixes this for later versions). An unknown field on the server
  already made their own upload look foreign; `uploadID` is such a field
  on every note a current client has saved. For those notes, an upload of
  theirs whose answer was lost and which was edited again is merged with a
  "(conflict)" copy instead of being recognised: the behaviour from before
  #229, and the safe direction.
- **Updating.** Uploads remembered by the previous version went up without
  an identity and can never be matched by one, so the local migration
  (`v14-sync-upload-identity`) forgets them. An upload in flight across
  the update is merged, with a copy when the text differs.
- **A record built without an identity** (the store cannot give one to a
  record without an edit date, which no note built here lacks) clears the
  server's value, because the adapter sets to nil every schema field a
  record leaves out (ADR 0011). A stale value is therefore never left by
  a current client beside content it did not go up with.

Every doubt resolves the same way: towards a merge, and a copy when the
texts differ. No rule here keeps one side silently on a guess.

## Consequences

- **The CloudKit schema gains `Note.uploadID`.** Production rejects a
  record with a field that is not deployed, so every save of a note from a
  build with this change fails there until the field is deployed. It must
  be in the Development schema (the seed build, CONTRIBUTING ▸ iCloud
  schema), checked against the previous released client in Development,
  and deployed to Production **before any release that contains this
  change**. The gate is written into `docs/plan/milestones.md`.
- `SyncMapping.schemaFields` lists the field; the schema seed carries it
  because the seed's note is sent through the same `pendingSave` as any
  other, and the test that keeps the seed in step with the schema builds
  its records that way.
- `SyncRecord.contentDigest` leaves the identity out, as it leaves the
  dates out: it describes the note, not the upload, and is the same for a
  record with and without one.
- A later field saved without an edit date needs nothing more: the
  identity covers it.
