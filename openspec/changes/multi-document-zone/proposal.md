# Proposal: one zone holds many documents

## Why

Today one `documentName` maps to one CloudKit zone
(`CloudKitRecordCodec.zoneID(forDocumentName:)`), and `CloudKitSyncStore`
routes every engine callback by zone to exactly one provider. That shape
made sense when a store held one document. It breaks down for the
subdocument model that `subdocument-support` enables: a consumer (the wiki
app) plans one root document per vault plus one subdocument per page. With
zone-per-document, a vault of N pages costs N+1 zones, N+1 change tokens,
and N+1 zone fetches at startup — and the zone stops being what it should
be: the per-vault boundary.

CloudKit does not ask for zone-per-document. A zone holds many records;
the zone is the atomic-commit boundary, the change-token boundary, the
bulk-delete boundary, and the sharing boundary. All four belong to the
store's dataset as a whole, not to one document. There is no consumer that
needs the old mapping, and the library is pre-1.0 with no deployments to
protect. So this change **replaces** the mapping instead of adding a mode
beside it.

There is a correctness problem hiding in the current router too.
`CKSyncEngine` fetches a zone's changes whether or not a provider is
attached, and `CloudKitSyncStore.dispatchFetched` drops records that no
provider owns while the change token advances. A consumer that starts
document providers lazily would silently lose remote edits. This change
fixes that with a persisted inbound spool.

## What Changes

- **BREAKING: one zone per store.** The codec takes a caller-supplied
  zone name at construction (the wiki app passes the vault UUID). Every
  document of the store lives in that zone. The zone-per-document mapping
  is deleted, not deprecated. Records written by the old mapping are not
  readable; there are no known deployments.
- **Document-scoped record names.** Record names carry an encoded
  document component (`doc.<enc>.incremental.<clientID>.<from>.<to>`,
  `doc.<enc>.snapshot`), because deleted-record callbacks carry only the
  `CKRecord.ID` and routing must work from the name alone. The existing
  `documentName` record field stays for validation.
- **Routing by document.** `CloudKitSyncStore` registers providers by
  document, parses the document from the record name, and dispatches
  fetched, sent, and record-to-save callbacks per document.
- **Inbound spool.** A fetched record whose document has no active
  provider is persisted in a store-backed spool. When that document's
  provider starts, the spool replays through the normal fetched path,
  then clears. No remote update is lost to lazy provider start.
- **Removal, two grains.** `removeDocument` deletes one document's
  records, driven by a persisted per-document registry of known record
  IDs (there is no query path through `CKSyncEngine`). `removeZone`
  deletes the whole zone — the consumer's "delete the vault".
- **Example and docs.** `Examples/TodoCloudKit` moves to the new codec
  API. README, `docs/feature-coverage.md`, and an ADR that records the
  zone decision and the spool.

## Capabilities

### New Capabilities

- `cloudkit-zone-sharing` — one zone per store: document-scoped record
  identity, per-document routing, the inbound spool, and per-document and
  per-zone removal.

## Impact

- `Sources/SwiftYrsCloudKit/CloudKitRecordCodec.swift`: required zone
  name, record-name building and parsing; the per-document zone function
  goes.
- `Sources/SwiftYrsCloudKit/CloudKitSyncStore.swift`: registry keyed by
  document, dispatch by parsed document, spool integration, `removeZone`,
  per-document `removeDocument`.
- New: inbound spool and known-record registry, persisted through
  `CloudKitMetadataStore` (SQLite and file backings exist).
- `Sources/SwiftYrsCloudKit/CloudKitProvider.swift`, `SnapshotWriter.swift`:
  minimal changes — both already scope every record ID by `documentName`
  through the codec.
- `Tests/SwiftYrsCloudKitTests`: routing, spool, and removal tests against
  `MockCloudKitSyncEngine`; existing tests update to the new codec API.
- `Examples/TodoCloudKit`: passes a zone name; otherwise unchanged.
- `docs/adr`: one new ADR. `README.md`, `docs/feature-coverage.md`.

## Out of Scope

- Reading records written by the old zone-per-document mapping. No known
  deployments; the ADR records the break.
- Application attachment sync (`CKAsset` blobs for app files). Separate
  proposal; one zone per vault makes it easier later.
- CloudKit sharing (`CKShare`) of the zone. Enabled by the shape, not
  implemented here.
- Changes to `SQLiteProvider` or the sync protocol payloads.
