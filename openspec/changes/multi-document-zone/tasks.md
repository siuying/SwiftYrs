Work test-first against `MockCloudKitSyncEngine`. This is a BREAKING
change: the zone-per-document mapping is deleted, and existing CloudKit
tests move to the new codec API as part of each slice, not in one big
sweep at the end.

## 1. Decision record

- [ ] 1.1 Write the ADR: one caller-named zone per store replaces
      zone-per-document; document-scoped record names; the inbound spool;
      best-effort per-document removal versus exact zone removal; the
      compatibility break and why it is acceptable now. Commit it with
      the first code.

## 2. Codec: zone name and record names

- [ ] 2.1 Red: codec tests — the codec requires a zone name; record IDs
      for two documents land in that one zone; record names carry the
      document component; round trip `documentName(fromRecordName:)`;
      malformed names throw.
- [ ] 2.2 Green: required `zoneName` in the initializer, name building,
      name parsing; delete `zoneID(forDocumentName:)`.
- [ ] 2.3 Decode verifies the record-name document equals the
      `documentName` field; mismatch throws a typed error.

## 3. Store: registry and routing

- [ ] 3.1 Red: two providers on one store; interleaved fetched and sent
      batches route each record to its own provider; `recordToSave`
      answers through the owning provider; deleted IDs route by name
      alone.
- [ ] 3.2 Green: registry keyed by document; dispatch groups by parsed
      document; zone-keyed lookups removed.
- [ ] 3.3 Update the existing store and provider tests to the new codec
      API; the full CloudKit suite passes.

## 4. Inbound spool

- [ ] 4.1 Red: fetch for an unregistered document, register later, the
      update applies; order preserved across several records; deletion
      tombstones replay.
- [ ] 4.2 Green: spool persisted through `CloudKitMetadataStore` under a
      reserved namespace; drain on registration before live dispatch.
- [ ] 4.3 Relaunch test: spool entries survive store teardown and
      recreation on the same metadata store.
- [ ] 4.4 Coalescing: a fetched snapshot drops covered spooled
      incrementals; a spooled snapshot replaces older spooled state.

## 5. Removal

- [ ] 5.1 Red: remove one document — its known records are enqueued for
      delete, its drain set, spool, and registry clear, the other
      document is untouched; removal throws while its provider is
      attached.
- [ ] 5.2 Green: persisted known-record registry, updated on sent and
      fetched events; `removeDocument` uses it.
- [ ] 5.3 `removeZone`: deletes the zone, clears all zone-scoped state;
      test that a fresh store start syncs nothing.

## 6. Example and docs

- [ ] 6.1 `Examples/TodoCloudKit`: pass a zone name; verify it builds and
      runs.
- [ ] 6.2 README: setup example (one store per vault, zone named by the
      caller, lazy per-document providers, `removeZone` as the dataset
      delete) and a BREAKING note for the old mapping.
- [ ] 6.3 `docs/feature-coverage.md`: update the CloudKit provider row.
- [ ] 6.4 Doc comments: per-document removal is best-effort, zone removal
      is exact; the spool and its coalescing rule.
