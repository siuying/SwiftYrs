# Design: subdocument content access

## Context

Verified against the pinned yrs 0.27.0 (git `ae61429`): `Doc` derives
`Clone` and holds `DocStore(Arc<StoreInner>)`, so clones share one store
(`doc.rs:54`, `store.rs:431`). `impl TryFrom<Out> for Doc` backs the map
value cast (`doc.rs:62`). `ReadTxn::subdocs()` iterates registered subdoc
`Doc`s (`transaction.rs:180`). Decoded subdoc entries keep the GUID and set
`should_load = false` (`doc.rs:618`).

The bridge already covers half of the yrs subdocument surface
(`map_set_new_subdoc`, `map_get_subdoc_guid`, `map_load_subdoc`,
`map_clear_subdoc`, `transaction_subdoc_guids`, `doc_observe_subdocs`).
The missing half is the content handle. In yrs, a subdocument is a real
`Doc` stored as a map value, and `Doc` clones share one store through an
internal `Arc`. The parent transaction can `cast::<Doc>()` the map value and
hand out a clone.

## Decisions

### A subdocument handle is a boxed `Doc` clone

The new bridge functions return `Box::into_raw(Box::new(subdoc.clone()))`.
The existing `yrs_bridge_doc_destroy` drops the box, which drops one `Arc`
reference. The parent keeps its own reference inside the map value, so the
order of release does not matter.

Consequence for Swift: the existing `YDoc` class wraps the pointer with no
change. `deinit` destroys the clone, not the subdocument. Every `YDoc` API
(read/write transactions, shared types, `encodeStateAsUpdateV1`,
`observeUpdates`, undo manager) works on the handle, because it is the same
document.

Alternative rejected: a separate `YSubdocDoc` type with a narrower surface.
It doubles the API for no safety gain; the handle IS a document.

### Two access paths: by map key, and by GUID

- `yrs_bridge_map_get_subdoc_doc(map, txn, key, doc_out)` — the direct
  path when the caller holds the map.
- `yrs_bridge_transaction_get_subdoc_doc_by_guid(txn, guid, doc_out)` —
  iterates `transaction.subdocs()` and matches the GUID. The consumer app
  stores GUIDs in its own records, so this path lets it open a page without
  walking the map first.

Both return `YRS_BRIDGE_ERR_TYPE_MISMATCH` when the key or GUID does not
name a subdocument. When two subdocuments share one GUID (a remote update
can craft this), the GUID path returns one of them and which one is
unspecified — `subdocs()` walks a `HashMap`, so there is no stable "first".
GUID uniqueness is the application's contract.

Swift surface (on the transaction, mirroring the existing subdoc methods):

```swift
public func subdocDoc(forKey key: String, in map: YMap) throws -> YDoc
public func subdocDoc(guid: String) throws -> YDoc
```

`YSubdoc` stays as it is: a value that carries the GUID. The docs state its
role: a reference, not a handle.

### The parent stream does not carry subdocument content

This is yrs behaviour, not a choice, but the API docs must say it loudly:

- A parent update contains the subdocument **entry** (GUID, flags), never
  the subdocument's content.
- A subdocument has its own update stream and state vector. It shares the
  parent's client ID: yrs assigns it when the transaction that added the
  subdocument commits (`transaction.rs:1102`), as Yjs does.
- A provider that persists the parent does not persist the subdocuments.
  Each subdocument needs its own provider; its GUID is a natural
  `documentName`.

A test pins this: edit a subdocument, assert the parent's update stream
stays silent; edit the parent, assert the subdocument's stream stays silent.

### Remote materialisation keeps the GUID

When replica B applies a parent update from replica A, yrs creates the
subdocument entry with A's GUID. B can then call `subdocDoc(forKey:)` and
get an empty document with the right GUID, ready for the subdocument's own
updates (from a provider or a transport). The interop fixture proves the
GUID survives Yjs → SwiftYrs, and the sync test proves SwiftYrs → SwiftYrs.

Note for consumers: two replicas that each call `setNewSubdoc` for the same
logical entity create two different GUIDs, and the map key merges to one
winner. Create the subdocument once, on one replica, or accept last-write-
wins on the key. The docs carry this warning.

### Lifecycle after `clearSubdoc` follows yrs destroy semantics

`clearSubdoc` calls `Doc::destroy(parent_txn)`. yrs has **no destroyed
flag** (`doc.rs:413`): destroy recursively destroys child subdocuments,
fires the destroy observers, detaches the store from the parent, and
replaces the parent map entry with a **fresh, unloaded `Doc` reference
with the same GUID** (`should_load = false`). This mirrors Yjs, where
destroy unloads an instance but keeps the entry.

Consequences the API documents and the tests pin:

- A held Swift handle stays memory-safe (the `Arc` keeps the allocation).
- A write through the held handle **succeeds silently** on the detached
  store. It never reaches the parent or any replica. The bridge does NOT
  invent an error here; that would diverge from yrs and Yjs.
- The app learns about the destroy through `observeDestroy` on the subdoc
  handle, or through the parent's `observeSubdocs` (removed + added, same
  GUID).
- Removing the entry itself is a plain map remove, a separate operation.
- A test holds a handle, clears the subdocument, writes through the held
  handle, and asserts: no crash, no effect on the parent, destroy event
  fired, entry still present with the same GUID, release safe in any
  order.

### `loadSubdoc` and `should_load` stay as they are

`map_set_new_subdoc` creates the document with default options. The load
flag matters to transports that fetch lazily; the consumer app drives
loading itself (it starts a provider when the user opens a page), so v1
does not expose `DocOptions`. Open question below.

## Risks

- **FFI ownership.** A wrong ownership model here corrupts memory. The
  mitigation is the clone rule (one box per handle, destroy drops the box)
  and an address-sanitizer CI job over the subdocument tests.
- **Transaction re-entrancy.** Opening a subdocument transaction while the
  parent transaction is open is legal in yrs (different documents), but the
  Swift layer's conflict rules must be tested for the nested case.
- **Yjs compat drift.** Yjs subdocument semantics (load events, GUID
  encoding) must match; the fixture generator pins them.

## Open questions

- Does v1 expose `DocOptions` (GUID choice, `should_load`, `auto_load`) at
  `setNewSubdoc`? yrs supports it: `impl Prelim for Doc` integrates an
  existing document, and `Options` carries a caller GUID. Caution: the
  prelim path **panics** when the document is already a subdocument
  elsewhere (`doc.rs:654`), so the bridge must check `parent_doc()` first
  and return an error. Deferred until a consumer needs it.
- Does `clearSubdoc` also need a "remove entry without destroy" variant
  (move a page between maps)? Deferred; move can be modelled at the app
  level by GUID reference.
- Arrays: the same two functions can exist for `YArray` indexes. Deferred
  until a consumer needs it.
