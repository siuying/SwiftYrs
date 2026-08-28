# Subdocument handles are boxed `Doc` clones

A subdocument is a real yrs `Doc` stored as a map value, and `Doc` holds its state behind an internal `Arc` (`yrs 0.27.0` at git `ae61429`: `doc.rs:54`, `store.rs:431`). The bridge therefore returns a subdocument as `Box::into_raw(Box::new(subdoc))`, where `subdoc` is the `Doc` obtained by casting the map value (`impl TryFrom<Out> for Doc`, `doc.rs:62`). The handle is a second reference to one shared store, not a copy of the content.

Ownership follows the Owned Handle rule already used for root documents: one box per handle, released by `yrs_bridge_doc_destroy`, which drops that box and one `Arc` reference. The parent keeps its own reference inside the map value, so releasing a subdocument handle before or after the parent is equally safe, and a handle stays valid after the parent clears the subdocument.

Swift wraps the handle in the existing `YDoc` class rather than a new type: the handle *is* a document, so transactions, shared types, update encoding, observers, undo, and providers all apply unchanged. `YSubdoc` keeps its narrower role as a pure GUID reference — the value an application stores in its own records — while `YDoc` is the handle that reads and writes content. A separate `YSubdocDoc` type was rejected because it would duplicate the whole document API for no safety gain.

The two access paths are `subdocDoc(forKey:in:)` (cast the value at a map key) and `subdocDoc(guid:)` (scan `ReadTxn::subdocs()` for a GUID, `transaction.rs:180`). Neither invents lifecycle state: yrs has no destroyed flag, so a write through a handle held across `clearSubdoc` succeeds silently on the detached store and reaches nobody, exactly as in yrs and Yjs (`doc.rs:413`).
