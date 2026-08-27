# Design: shared zone, document-scoped records, inbound spool

## Context

Code facts this design builds on (verified in the current sources):

- `CloudKitRecordCodec.zoneID(forDocumentName:)` is the only place the
  document-to-zone mapping exists. Zone name: `swiftyrs.<b64(docName)>`.
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

### Zone mode lives in the codec, chosen at construction

```swift
public enum CloudKitZoneMode: Sendable {
    case zonePerDocument                 // legacy, default
    case sharedZone(zoneName: String)    // e.g. the vault UUID
}
```

`CloudKitRecordCodec` takes the mode. `zoneID(forDocumentName:)` returns
the shared zone in shared mode. The default stays `zonePerDocument`, so
every existing caller compiles and behaves as before. No migration logic
in SwiftYrs: a deployment picks one mode per store and stays on it. The
docs say plainly that switching modes on live data is not supported.

Alternative rejected: a mapping closure `(documentName) -> zoneName`.
More general, but it invites many-zone layouts we do not want to route or
test, and both known consumers need exactly one zone per store.

### Record names carry the document; parsing is the routing key

Shared-zone record names:

```
doc.<enc(documentName)>.incremental.<clientID>.<from>.<to>
doc.<enc(documentName)>.snapshot
```

`<enc>` is the existing URL-safe base64 (`encodedComponent`), which never
contains `.`, so splitting on `.` is unambiguous. The codec gains
`documentName(fromRecordName:)` used by the store for routing — including
deleted IDs, which have no fields. Legacy-mode names stay exactly as they
are, so existing records decode unchanged.

The `documentName` field stays on the record and the decode path verifies
name-versus-field agreement, failing loudly on a mismatch rather than
applying an update to the wrong document.

### The store routes by document, not by zone

`CloudKitSyncStore` replaces `providersByZone` with a registry keyed by
`documentName` (the zone is no longer unique). Dispatch groups records by
the parsed document and delivers to that provider. `recordToSave` parses
the ID the same way. Provider code does not change its contract: it still
sees only its own document's records.

Registration conflict rules stay per document (`duplicateProvider`,
`activeProvider`), unchanged.

### Inbound spool: no fetched record is dropped

New store-level component, persisted, keyed by document:

- On `dispatchFetched`, records for a document with **no** active provider
  are encoded (system fields plus payload fields) and appended to the
  spool; deleted IDs likewise, as tombstones.
- On provider registration, the store drains that document's spool through
  the provider's normal `handleFetched` path, in arrival order, before
  live dispatch resumes; then clears the drained entries.
- The spool persists through the `CloudKitMetadataStore` protocol (both
  SQLite and file backings exist), under a reserved key namespace, so a
  relaunch keeps spooled updates. Yrs updates are idempotent and
  commutative, so replay-after-crash duplicates are safe.

In legacy mode the spool also applies (a fetched zone with no provider),
fixing the same silent-drop hole there — but the primary driver is
shared-zone lazy providers.

Alternative rejected: requiring every document's provider before
`start()`. It defeats lazy loading, which is the reason the consumer wants
subdocuments.

### Known-record registry makes per-document removal possible

`CKSyncEngine` has no query path, so deleting one document's records needs
their IDs. The store maintains a persisted per-document set of known
record IDs, updated on `sentChanges` (saved) and `fetchedChanges`
(modified adds, deleted removes). In shared-zone mode:

- `removeDocument(named:)` enqueues deletes for that document's known
  records, clears its drain set, spool, and registry entries. It throws
  `activeProvider` while a provider is attached, as today.
- `removeZone()` (new) deletes the whole zone — every document at once —
  and clears all shared state. This is the consumer's vault delete.

Legacy mode keeps the current behaviour: `removeDocument` deletes the
document's zone.

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

One store per vault: shared zone named by the vault UUID. Root document
provider starts at vault open; page providers start lazily on page open;
remote edits to closed pages wait in the spool. Vault delete is
`removeZone()`. Fetch traffic is per-vault, not per-page.

## Risks

- **Spool growth.** A user who never opens a page accumulates its remote
  updates. Bounded in practice by snapshot compaction (a snapshot record
  replaces the incrementals), but the spool needs a coalescing rule: when
  a snapshot for a document arrives, drop that document's spooled
  incrementals covered by the snapshot's state vector. A test pins this.
- **Record-name parsing is now load-bearing.** A malformed name in the
  shared zone must fail into an error stream, never route to the wrong
  provider. Fuzz-style tests on the parser.
- **Zone record count.** One vault's pages and history now share one
  zone's limits. Snapshot compaction keeps per-document record counts
  small; the ADR notes the practical guidance and no hard limit.
- **Two modes to test.** Every routing test runs in both modes; legacy
  regression is part of the suite, not an afterthought.

## Open questions

- Does the spool cap total size per document (drop-oldest is wrong for
  CRDT updates; the correct degrade is forcing a snapshot fetch)? V1:
  no cap, coalesce on snapshot; revisit with real numbers.
- Should `removeZone` also clear the store's engine state, or only the
  zone-scoped state? Leaning zone-scoped only; verify against
  `CKSyncEngine` zone-deletion event behaviour during implementation.
- A migration utility (legacy zones → shared zone) — deferred until a
  consumer has live legacy data to move.
