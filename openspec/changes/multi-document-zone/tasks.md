Work test-first against `MockCloudKitSyncEngine`. Every routing test runs
in both zone modes; legacy behaviour is a regression suite, not an
afterthought. This change depends on nothing from `subdocument-support`
at the code level, but the two land best in that order.

## 1. Decision record

- [ ] 1.1 Write the ADR: one shared zone per store; document-scoped
      record names; the inbound spool; best-effort per-document removal
      versus exact zone removal. Commit it with the first code.

## 2. Codec: zone mode and record names

- [ ] 2.1 Red: shared-zone codec tests — zone ID for two documents is one
      zone; record names carry the document component; round trip
      `documentName(fromRecordName:)`; malformed names throw; legacy
      names still parse and still map one zone per document.
- [ ] 2.2 Green: `CloudKitZoneMode`, name building, name parsing.
- [ ] 2.3 Decode verifies record-name document equals the `documentName`
      field; mismatch throws a typed error. Test both modes.

## 3. Store: registry and routing

- [ ] 3.1 Red: two providers on one shared zone; interleaved fetched and
      sent batches route each record to its own provider; `recordToSave`
      answers through the owning provider.
- [ ] 3.2 Green: registry keyed by document; dispatch groups by parsed
      document; zone-keyed lookups removed.
- [ ] 3.3 Legacy regression: existing store tests pass unchanged in
      default mode.

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
- [ ] 4.5 Legacy mode gets the same spool behaviour (no silent drop).

## 5. Removal

- [ ] 5.1 Red: remove one document from a shared zone — its known records
      are enqueued for delete, its drain set, spool, and registry clear,
      the other document is untouched; removal throws while its provider
      is attached.
- [ ] 5.2 Green: persisted known-record registry, updated on sent and
      fetched events; `removeDocument` uses it.
- [ ] 5.3 `removeZone`: deletes the zone, clears all zone-scoped state;
      test that a fresh store start syncs nothing.
- [ ] 5.4 Legacy regression: `removeDocument` still deletes the
      document's zone in default mode.

## 6. Docs

- [ ] 6.1 README: shared-zone setup example (one store per vault, lazy
      per-document providers, `removeZone` as the vault delete).
- [ ] 6.2 `docs/feature-coverage.md`: note the zone modes on the CloudKit
      provider row.
- [ ] 6.3 Doc comments: switching zone modes on live data is not
      supported; per-document removal is best-effort, zone removal is
      exact.
