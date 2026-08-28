# Proposal: many documents in one CloudKit zone

## Why

Today one `documentName` maps to one CloudKit zone
(`CloudKitRecordCodec.zoneID(forDocumentName:)`), and `CloudKitSyncStore`
routes every engine callback by zone to exactly one provider. That was the
right shape for one document per store. It breaks down for the
subdocument model that `subdocument-support` enables: a consumer (the wiki
app) plans one root document per vault plus one subdocument per page. With
the current mapping, a vault of N pages costs N+1 zones, N+1 change
tokens, and N+1 zone fetches at startup — and the zone stops being what it
should be: the per-vault boundary.

CloudKit does not require this. A zone holds many records; the zone is the
atomic-commit boundary, the change-token boundary, the bulk-delete
boundary, and the sharing boundary. All four belong to the vault, not to
the page. This change lets one zone carry the records of many documents.

There is a correctness problem hiding here too. `CKSyncEngine` fetches a
zone's changes whether or not a provider is attached, and
`CloudKitSyncStore.dispatchFetched` drops records that no provider owns
while the change token advances. A consumer that starts page providers
lazily would silently lose remote edits to closed pages. This change fixes
that with a persisted inbound spool, which lazy-loading consumers need.

## What Changes

- **Shared-zone mode.** The codec accepts a zone name at construction. In
  shared-zone mode every document of the store lives in that one zone. The
  current one-zone-per-document mapping remains as legacy mode; existing
  deployments keep working with no migration.
- **Document-scoped record names.** Record names gain an encoded document
  component (`doc.<enc>.incremental.<clientID>.<from>.<to>`,
  `doc.<enc>.snapshot`), because deleted-record callbacks carry only the
  `CKRecord.ID` and routing must work from the name alone. The existing
  `documentName` record field stays for validation.
- **Routing by document.** `CloudKitSyncStore` registers providers by
  document, parses the document from the record name, and dispatches
  fetched, sent, and record-to-save callbacks per document instead of per
  zone.
- **Inbound spool.** A fetched record whose document has no active
  provider is persisted in a store-backed spool. When that document's
  provider starts, the spool replays through the normal fetched path, then
  clears. No remote update is lost to lazy provider start.
- **Per-document removal.** In shared-zone mode `removeDocument` deletes
  only that document's records, driven by a persisted per-document
  registry of known record IDs (there is no query path through
  `CKSyncEngine`). A new `removeZone` deletes the whole zone — the
  consumer's "delete the vault" operation.
- **Docs and coverage.** README, `docs/feature-coverage.md`, and an ADR
  that records the zone-sharing decision and the spool.

## Capabilities

### New Capabilities

- `cloudkit-zone-sharing` — shared-zone mode: document-scoped record
  identity, per-document routing, the inbound spool, per-document and
  per-zone removal, and legacy-mode compatibility.

## Impact

- `Sources/SwiftYrsCloudKit/CloudKitRecordCodec.swift`: zone mode, record
  name prefix, record-name parsing.
- `Sources/SwiftYrsCloudKit/CloudKitSyncStore.swift`: registry keyed by
  document, dispatch by parsed document, spool integration, `removeZone`,
  per-document `removeDocument`.
- New: inbound spool and known-record registry, persisted through
  `CloudKitMetadataStore` (or a sibling protocol with the same SQLite and
  file backings).
- `Sources/SwiftYrsCloudKit/CloudKitProvider.swift`, `SnapshotWriter.swift`:
  record-ID construction goes through the codec as today; changes are
  minimal because both already scope every ID by `documentName`.
- `Tests/SwiftYrsCloudKitTests`: shared-zone routing, spool, removal, and
  legacy-mode regression tests against `MockCloudKitSyncEngine`.
- `Examples/TodoCloudKit`: unchanged (legacy mode); a doc note shows the
  shared-zone setup.
- `docs/adr`: one new ADR. `README.md`, `docs/feature-coverage.md`.

## Out of Scope

- Automatic migration of existing per-document zones into a shared zone.
  Legacy mode keeps them working; a migration utility is a later change if
  a consumer needs it.
- Application attachment sync (`CKAsset` blobs for app files). Separate
  proposal; this change makes it easier by giving the app one zone per
  vault to put them in.
- CloudKit sharing (`CKShare`) of the zone. The zone-per-vault shape
  enables it later; nothing here implements it.
- Changes to `SQLiteProvider` or the sync protocol payloads.
