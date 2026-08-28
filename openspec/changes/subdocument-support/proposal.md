# Proposal: full subdocument support

## Why

The current subdocument API is half of the feature. A map can hold a
subdocument (`setNewSubdoc`), the app can read its GUID, load it, clear it,
list the GUIDs, and observe subdocument events. But every path returns only
the GUID. There is no way to get a `YDoc` for the subdocument's content.

Without the content handle, an app cannot:

- read or write the subdocument's shared types;
- observe the subdocument's updates;
- attach a provider (`SQLiteProvider`, `CloudKitProvider`) to the
  subdocument;
- apply a remote update to the subdocument.

A concrete consumer needs this now: the wiki app plans a root document that
holds vault metadata and the folder structure, with one subdocument per page.
The root document stays small and loads at vault open; a page body loads only
when the user opens the page. That design is blocked on this gap.

The bridge can close the gap safely. A yrs `Doc` shares its state through an
internal `Arc`, so the bridge can return a boxed clone of the subdocument's
`Doc`, and the existing `yrs_bridge_doc_destroy` drops that clone without
harm to the parent.

## What Changes

- **Content access.** A new bridge function returns the subdocument at a map
  key as a `Doc` handle (a boxed clone). Swift wraps it in the existing
  `YDoc` type, so every current `YDoc` API — transactions, shared types,
  update encoding, observation, undo — works on a subdocument with no new
  surface.
- **Access by GUID.** The transaction can also return the subdocument `Doc`
  for a known GUID, so an app that stores GUIDs can open a subdocument
  without the map key.
- **Remote materialisation.** Applying a parent update that contains a
  subdocument entry gives the receiving replica the same GUID, and the
  receiver can get the content handle for it. A test proves the round trip
  against a Yjs fixture.
- **Lifecycle safety.** `clearSubdoc` follows yrs destroy semantics: the
  instance detaches, destroy observers fire, and the parent entry stays as
  an unloaded reference with the same GUID. A held Swift handle stays safe
  to use and to release; a write through it goes to the detached instance
  and reaches nobody. No invented error codes — the behaviour matches yrs
  and Yjs.
- **Provider compatibility.** A test proves that `SQLiteProvider` persists
  and reconstructs a subdocument through its GUID as `documentName`, in the
  same `SQLiteStore` as the parent. No provider code changes.
- **Documented boundary.** The docs state plainly: a parent document's
  update stream does NOT contain subdocument content. Each subdocument has
  its own updates, its own state vector, and needs its own provider.
- **Docs and coverage.** README, `docs/feature-coverage.md`, and
  `CONTEXT.md` reflect the completed feature. An ADR records the
  clone-handle ownership decision.

## Capabilities

### New Capabilities

- `subdocuments` — create, reference, load, clear, and now **open**
  subdocuments as full `YDoc` values; independence of parent and
  subdocument update streams; provider attachment.

## Impact

- `native/yrs-bridge/src/lib.rs`: new functions
  `yrs_bridge_map_get_subdoc_doc` and
  `yrs_bridge_transaction_get_subdoc_doc_by_guid`; header regeneration.
- `Sources/SwiftYrs`: `YSharedTypes.swift` (transaction methods that return
  `YDoc`), possibly `YSubdoc` gaining a documented role as a pure GUID
  reference.
- `Tests/SwiftYrsTests`: subdocument content, lifecycle, and update
  independence tests.
- `Tests/SwiftYrsSQLiteTests`: provider-on-subdocument test.
- `scripts/generate-yjs-fixtures.mjs` and `Fixtures`: a Yjs interop case
  with a subdocument.
- `docs/adr`: one new ADR (subdocument handles are Arc clones).
- `README.md`, `docs/feature-coverage.md`, `CONTEXT.md`.

## Out of Scope

- Subdocuments inside `YArray` or `YText` embeds. Maps only for v1; the
  consumer needs maps. The bridge shape extends to arrays later.
- Inserting an **existing** local `YDoc` as a subdocument (Yjs prelim-doc
  insert). Not needed by the consumer; noted as an open question in the
  design.
- Provider changes. `SQLiteProvider` and `CloudKitProvider` already accept
  any `YDoc`; this change only proves the combination.
- Zone multiplexing for CloudKit (many subdocuments in one zone). That is a
  separate proposal if the consumer needs it.
