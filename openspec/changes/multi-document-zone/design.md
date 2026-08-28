# Design: one zone per store, document-scoped records, inbound spool

## Context

Code facts this design builds on (verified in the current sources):

- `CloudKitRecordCodec.zoneID(forDocumentName:)` is the only place the
  document-to-zone mapping exists. Zone name today:
  `swiftyrs.<b64(docName)>`.
- Record names are zone-scoped: `incremental.<clientID>.<from>.<to>` and a
  singleton `snapshot`. In a shared zone the snapshot collides at once,
  and incrementals collide when two documents see the same client ID.
- Every record already carries a `documentName` field — but deleted-record
  callbacks deliver only `CKRecord.ID`, so a field is not enough for
  routing.
- `CloudKitSyncStore` holds `providersByZone` and dispatches
  `recordToSave`, `dispatchFetched`, and `dispatchSent` by `zoneID`.
- `dispatchFetched` silently drops records with no registered provider,
  while the engine's change token advances. Records dropped this way are
  gone.
- `removeDocument` deletes the document's zone.
- Drain sets, sync state, and metadata are already keyed by
  `documentName` through `CloudKitMetadataStore` — unaffected.

## Decisions

### One zone per store; the caller names it

```swift
public init(zoneName: String, assetDirectory: URL,
            inlineBytesLimit: Int = Self.defaultInlineBytesLimit)
```

The codec requires a zone name at construction. Every document of the
store lives in `CKRecordZone.ID(zoneName: "swiftyrs.<enc(zoneName)>")`.
The wiki app passes the vault UUID; `TodoCloudKit` passes a constant.
`zoneID(forDocumentName:)` is deleted.

This **replaces** the old mapping. Records written under zone-per-document
are not readable by the new code. The library is pre-1.0 with no known
deployments; the ADR records the break instead of a compatibility layer.
Keeping both mappings would double the routing paths and the test matrix
for a consumer that does not exist.

Alternative rejected: a mapping closure `(documentName) -> zoneName`.
More general, but it invites many-zone layouts we do not want to route or
test, and both known consumers need exactly one zone per store.

### Record names carry the document; parsing is the routing key

```
doc.<enc(documentName)>.incremental.<clientID>.<from>.<to>
doc.<enc(documentName)>.snapshot
```

`<enc>` is the existing URL-safe base64 (`encodedComponent`), which never
contains `.`, so splitting on `.` is unambiguous. The codec gains
`documentName(fromRecordName:)`, used by the store for all routing —
including deleted IDs, which have no fields.

The `documentName` field stays on the record, and decode verifies
name-versus-field agreement, failing with a typed error on a mismatch
rather than applying an update to the wrong document.

### The store routes by document, not by zone

`CloudKitSyncStore` replaces `providersByZone` with a registry keyed by
`documentName`. Dispatch groups records by the parsed document and
delivers to that provider. `recordToSave` parses the ID the same way.
The provider contract does not change: a provider still sees only its own
document's records.

Registration conflict rules stay per document (`duplicateProvider`,
`activeProvider`), unchanged.

### Inbound spool: no fetched record is dropped

New store-level component, persisted, keyed by document:

- On `dispatchFetched`, records for a document with **no** active provider
  are encoded and appended to the spool; deleted IDs likewise, as
  tombstones.
- On provider registration, the store drains that document's spool through
  the provider's normal `handleFetched` path, in arrival order, before
  live dispatch resumes; then clears the drained entries.
- Implementation note: this became *every* fetched change, not only the
  un-owned ones. Two paths needed a flag to say which one a document was
  on, and the live path kept the same hole in miniature — a change applied
  straight from the callback is lost if the process dies mid-apply,
  because the token has already moved. One queue makes arrival order a
  property of the data instead of the code. A batch is dropped only after
  the provider has applied it, by sequence number, so a snapshot
  coalescing the queue during a replay cannot shift what gets dropped.
- The spool persists through the `CloudKitMetadataStore` protocol (SQLite
  and file backings exist), under a reserved key namespace, so a relaunch
  keeps spooled updates. Yrs updates are idempotent and commutative, so
  replay-after-crash duplicates are safe.

This also closes the silent-drop hole for any document whose provider is
not yet started, which exists in the current code independently of the
zone question.

Alternative rejected: requiring every document's provider before
`start()`. It defeats lazy loading, which is the reason the consumer wants
subdocuments.

### Known-record registry makes per-document removal possible

`CKSyncEngine` has no query path, so deleting one document's records needs
their IDs. The store maintains a persisted per-document set of known
record IDs, updated on `sentChanges` (saved) and `fetchedChanges`
(modified adds, deleted removes).

- `removeDocument(named:)` enqueues deletes for that document's known
  records and clears its drain set, spool, and registry entries. It
  throws `activeProvider` while a provider is attached, as today.
- `removeZone()` (new) deletes the whole zone — every document at once —
  and clears all zone-scoped state. This is the consumer's vault delete.

The registry can lag reality (a crash between server accept and registry
write). `removeZone` is exact; per-document removal is best-effort plus
the next snapshot cycle's garbage collection. The ADR records this
honestly.

### What does not change

- `CloudKitProvider`, `SnapshotWriter`, `DrainSetManager`,
  `RecoveryPlanner`, compaction, debounce, and the record payloads. Every
  record ID they touch is already built through the codec with a
  `documentName` argument, which is why this change stays contained.
- One `CKSyncEngine` per store, one engine-state blob, account-change
  handling.

## Consumer shape (wiki app, for orientation)

One store per vault: the zone is named by the vault UUID. The root
document provider starts at vault open; page providers start lazily on
page open; remote edits to closed pages wait in the spool. Vault delete is
`removeZone()`. Fetch traffic is per-vault, not per-page.

## Risks

- **Spool growth.** A user who never opens a page accumulates its remote
  updates. Bounded in practice by snapshot compaction (a snapshot record
  replaces the incrementals), plus a coalescing rule: when a snapshot for
  a document arrives, drop that document's spooled incrementals covered by
  the snapshot's state vector. A test pins this.
- **Record-name parsing is now load-bearing.** A malformed name must fail
  into an error stream, never route to the wrong provider. Fuzz-style
  tests on the parser.
- **CloudKit name lengths.** Found during implementation: CloudKit raises
  an Objective-C exception (an uncatchable crash from Swift) for a record
  or zone name over 255 characters, and the encoded document component
  inflates a name by 4/3. So the codec's initializer throws on an
  over-long zone name, and `codec.documentKey(_:)` throws on an over-long
  document name. That key is the only throwing step: holding a
  `CloudKitDocumentKey` is the proof that lets every record-ID builder be
  non-throwing, so no inbound or GC path has to treat "name too long" as
  a possible outcome. `CloudKitProvider.init` takes the key, so an
  unusable name fails at setup rather than at the first flush.
- **Zone record count.** All documents of a store now share one zone's
  limits. Snapshot compaction keeps per-document record counts small; the
  ADR notes the practical guidance and no hard limit.
- **The break itself.** Any experiment that wrote real data under the old
  mapping loses sync history (local SQLite state is untouched). Accepted
  and recorded; the first sync after the change re-seeds the zone from a
  snapshot.

## Open questions

- Does the spool cap total size per document (drop-oldest is wrong for
  CRDT updates; the correct degrade is forcing a snapshot fetch)? V1:
  no cap, coalesce on snapshot; revisit with real numbers.
- Should `removeZone` also clear the store's engine state, or only the
  zone-scoped state? Leaning zone-scoped only; verify against
  `CKSyncEngine` zone-deletion event behaviour during implementation.
