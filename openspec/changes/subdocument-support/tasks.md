Work test-first: each bridge function lands with its Swift test red before
the Rust code turns it green.

## 1. Decision record

- [x] 1.1 Write the ADR: a subdocument handle is a boxed `Doc` clone; the
      existing destroy drops one reference; `YSubdoc` stays a GUID
      reference. Commit it with the first bridge code.

## 2. Bridge: content access

- [x] 2.1 Red: a Swift test opens a subdocument by key and reads a text
      written through another handle.
- [x] 2.2 Green: `yrs_bridge_map_get_subdoc_doc(map, txn, key, doc_out)` —
      cast the map value to `Doc`, box a clone, write the pointer.
      Type-mismatch error for a non-subdocument value.
- [x] 2.3 Red: a Swift test opens a subdocument by GUID.
- [x] 2.4 Green: `yrs_bridge_transaction_get_subdoc_doc_by_guid(txn, guid,
      doc_out)` over `transaction.subdocs()`.
- [ ] 2.5 Regenerate the bridge header, and rebuild for Mac and Linux.

## 3. Swift surface

- [x] 3.1 `subdocDoc(forKey:in:) -> YDoc` and `subdocDoc(guid:) -> YDoc`
      on the transaction types, next to the existing subdoc methods.
- [x] 3.2 Doc comments: the handle is the same document; the parent stream
      does not carry subdocument content; each subdocument needs its own
      provider; two replicas that both create a subdocument for one
      logical entity race on the map key.

## 4. Behaviour tests

- [x] 4.1 Update independence: edit the subdocument, the parent stream is
      silent; edit the parent, the subdocument stream is silent.
- [x] 4.2 Replication: A's parent update plus A's subdocument update give B
      the same GUID and the same text.
- [x] 4.3 Lifecycle: hold a handle, `clearSubdoc`, write through the held
      handle — no crash, no effect on the parent, destroy event fires,
      the parent entry keeps the GUID unloaded; release in both orders.
      Run under address sanitizer.
- [x] 4.4 Nested transactions: a subdocument write inside a parent read and
      the reverse; pin the conflict rules.

## 5. Interop fixture

- [ ] 5.1 Extend `scripts/generate-yjs-fixtures.mjs`: a Yjs doc with a map
      that holds a subdocument, exported as parent update, subdocument
      GUID, and subdocument update.
- [ ] 5.2 Swift test: apply the fixture, list the GUID, open the
      subdocument, read the content.

## 6. Provider proof

- [ ] 6.1 `SQLiteProvider` test: parent provider plus subdocument provider
      on one `SQLiteStore`, restart, both reconstruct
      (`documentName` = subdocument GUID).
- [ ] 6.2 Document the pattern in the SQLite provider README section:
      lazy open — start a subdocument provider when the app needs the
      content, stop it when done.

## 7. Docs

- [ ] 7.1 `docs/feature-coverage.md`: move Subdocuments to full coverage
      with the new functions listed.
- [ ] 7.2 `README.md` feature table and a short subdocument example.
- [ ] 7.3 `CONTEXT.md`: subdocument glossary entry (reference vs handle).
