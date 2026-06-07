# swift-yjs

Swift binding for Yrs, which is a port of the Yjs framework.. Its language keeps the core document/protocol API separate from optional transport integrations.

## Language

**Core Swift Package**:
The Swift 6 API surface for Yjs/Yrs document types, transactions, updates, state vectors, snapshots, awareness, and sync protocol messages. It excludes concrete network transports.
_Avoid_: Provider package, app sync layer

**Network Provider**:
An optional transport integration that sends and receives Core Swift Package protocol payloads over a concrete network such as WebSocket or WebRTC.
_Avoid_: Core library, sync protocol

**FFI Surface**:
The C ABI exported by `yffi` or a local fork/shim of it. It is the boundary the Swift package wraps, not the API Swift users should write against directly.
_Avoid_: Swift API, public model

**Shim ABI**:
The project-owned C ABI wrapped by Swift. It may forward to upstream `yffi`, a local `yffi` fork, or direct `yrs` calls, but it is the stable native boundary exposed to the XCFramework.
_Avoid_: Upstream yffi API, Swift API

**Rust Shim Crate**:
The Rust crate that exports the Shim ABI as C symbols and links to `yrs` or `yffi` internally.
_Avoid_: C wrapper layer, Swift wrapper

**Owned Handle**:
An opaque native pointer returned by the Shim ABI that the Swift wrapper must release with the matching shim destroy function.
_Avoid_: Borrowed handle, raw pointer

**Borrowed Handle**:
An opaque native pointer that is valid only under a documented owner or callback/transaction lifetime and must not be destroyed by Swift.
_Avoid_: Owned handle, retained object

**Shim Buffer**:
A byte or string allocation returned by the Shim ABI and released only by the matching shim buffer/string destroy function.
_Avoid_: Swift-owned Data storage, libc free

**XCFramework Bundle**:
The Apple-platform binary package containing the native FFI library and generated C headers used by Swift Package Manager.
_Avoid_: Swift wrapper, provider

**Initial Apple Matrix**:
The first XCFramework target set: arm64 macOS, arm64 iOS device, and arm64 iOS simulator. Intel macOS and Intel iOS simulator support are out of the initial target.
_Avoid_: Universal Apple support, legacy Intel support

**Binary Artifact Release**:
A checksumed SwiftPM binary target ZIP containing the XCFramework Bundle for downstream consumers. It is the release distribution form, distinct from local vendoring during development.
_Avoid_: Development artifact, source package

**SwiftPM Package**:
The only initial Swift distribution format for the Core Swift Package and Binary Artifact Release.
_Avoid_: CocoaPods, Carthage

**Feature Coverage Matrix**:
The first planning artifact for the Swift binding, mapping every targeted y-crdt README feature to `yrs` support, current `yffi` support, Swift API shape, FFI gaps, and required tests.
_Avoid_: Informal checklist, README claim

**Interop Fixture**:
A cross-language compatibility case, preferably generated or checked with JavaScript Yjs, used to prove encoded updates, state vectors, awareness payloads, or sync protocol messages behave compatibly.
_Avoid_: Swift-only unit test

**Shared Type**:
A live CRDT branch such as text, array, map, XML, or weak link, exposed in Swift as a reference type because it has shared identity inside a document.
_Avoid_: Value object, copied collection

**Payload Value**:
An immutable Swift value representing encoded or derived CRDT data, such as an update, state vector, snapshot, relative position, event delta, or options object.
_Avoid_: Shared type, live branch

**Typed Payload**:
A distinct Swift value type wrapping encoded bytes for one CRDT/protocol concept, such as `YUpdate`, `YStateVector`, `YSnapshot`, `YAwarenessUpdate`, or `YSyncMessage`.
_Avoid_: Raw Data, interchangeable bytes

**YValue**:
The Swift enum used to represent heterogeneous Yjs/Yrs content at the FFI boundary and inside shared arrays/maps. It covers JSON-like scalars, binary data, nested shared types, subdocuments, XML nodes, weak links, null, and undefined.
_Avoid_: Generic element type, Codable-only model

**CRDT Index**:
An integer position used by Yjs/Yrs shared sequence types such as text, arrays, and XML children. It is the core API index model; Swift `String.Index` helpers are optional conveniences over local snapshots.
_Avoid_: Swift String.Index, UTF-16 offset

**Codable Bridge**:
A deferred convenience layer for encoding and decoding the JSON-compatible subset of YValue into application-specific Swift types.
_Avoid_: Core content model, complete Yjs representation

**YError**:
The Swift error type that normalizes failed native operations, decode/apply failures, type mismatches, missing required shared types, invalid transaction use, and FFI invariants.
_Avoid_: Raw error code, null sentinel

**Y-prefixed Type Name**:
A public Swift type name that preserves Yjs/Yrs recognition, such as `YDoc`, `YText`, or `YAwareness`.
_Avoid_: Unprefixed domain alias, C-style function name

**Swift-native Method Label**:
A method name and argument-label shape following Swift API conventions while operating on Y-prefixed types.
_Avoid_: Transliterated C function, Rust method spelling

**Document Handle**:
The synchronous Swift reference type representing a Yrs document. It owns the native document pointer and exposes access through closure-scoped reads and writes.
_Avoid_: Actor, async document

**Observation**:
A cancellable Swift reference that owns a native `yffi` subscription. Cancelling or deinitializing it unregisters the callback.
_Avoid_: Event stream, transaction

**Event Stream**:
An `AsyncSequence` convenience layer over an Observation. It is ergonomic Swift API, not the primitive native subscription owner.
_Avoid_: Native subscription, provider

**Signaling Server**:
A WebSocket pub/sub relay that lets WebRTC peers in the same Room discover each other and exchange connection-establishment messages. It never sees document content or awareness; with a password set, even the relayed messages are encrypted from it.
_Avoid_: Sync server, Hocuspocus server, backend

**Room**:
The named channel WebRTC peers join to collaborate on one document. It is the WebRTC transport's identity for a shared document and corresponds to the provider's document name.
_Avoid_: Channel, topic, session

**Mesh Topology**:
The WebRTC connection shape where every Peer holds a direct data-channel connection to every other Peer in a Room, bounded by a maximum connection count. It contrasts with the single client-to-server link of the WebSocket transport.
_Avoid_: Star, hub-and-spoke, client-server

**Peer Signal**:
A simple-peer-shaped connection-establishment payload (offer, answer, ICE candidate, or renegotiate) relayed through the Signaling Server to bring up a direct WebRTC connection. It is distinct from sync and awareness payloads, which travel over the established data channel.
_Avoid_: SDP blob, ICE message, sync message

## Example Dialogue

Dev: "Does the Core Swift Package include WebSocket sync?"

Domain expert: "No. It exposes update, awareness, and sync protocol payloads. A Network Provider can carry those bytes over WebSocket later."

Dev: "If upstream yffi lacks awareness exports, where does that belong?"

Domain expert: "That is an FFI Surface gap. Fill it in yffi or a shim, then wrap it with Swift-native types."

Dev: "Should Swift import upstream yffi symbols directly?"

Domain expert: "No. Swift wraps the project-owned Shim ABI, which can forward to yffi or patch gaps behind a stable boundary."

Dev: "Where should missing Awareness exports be implemented?"

Domain expert: "In the Rust Shim Crate, using direct `yrs` access if upstream yffi does not expose enough."

Dev: "Can Swift free Rust-returned bytes with `free`?"

Domain expert: "No. Rust-returned bytes are Shim Buffers and must be released with the matching shim destroy function."

Dev: "Does the first XCFramework need Intel simulator slices?"

Domain expert: "No. The Initial Apple Matrix is arm64 macOS plus arm64 iOS device and simulator."

Dev: "Should app developers build Rust when they add the package?"

Domain expert: "No. They should consume a Binary Artifact Release. Local vendoring is for development of the binding itself."

Dev: "Do we need CocoaPods for the first release?"

Domain expert: "No. The initial distribution is SwiftPM Package only."

Dev: "How do we know the Swift library is complete?"

Domain expert: "The Feature Coverage Matrix defines completeness, and every completed row needs test coverage."

Dev: "Are Swift roundtrip tests enough for encoded updates?"

Domain expert: "No. Binary/protocol rows also need Interop Fixtures, with JavaScript Yjs as the compatibility authority."

Dev: "Can copying a YText copy its document content?"

Domain expert: "No. A YText is a Shared Type, so it is a reference to live CRDT state. Encoded updates and snapshots are Payload Values."

Dev: "Can I pass a state vector anywhere Data is accepted?"

Domain expert: "No. Encoded protocol bytes are Typed Payloads so state vectors, updates, and awareness updates are not interchangeable."

Dev: "Should YMap be generic over one Swift value type?"

Domain expert: "No. Yjs containers are heterogeneous, so the core model uses YValue. Typed helpers can sit on top."

Dev: "Can Codable represent every Yjs value?"

Domain expert: "No. Codable Bridge is deferred and only applies to a JSON-compatible subset."

Dev: "Should YText use Swift String.Index?"

Domain expert: "No. Core text operations use CRDT Indexes for Yjs/Yrs parity."

Dev: "Should apply-update return an integer error code?"

Domain expert: "No. Failed native operations throw YError; optional results are only for legitimate absence."

Dev: "Should the Swift type be named Document?"

Domain expert: "No. Use Y-prefixed Type Names for parity, then make the method labels Swift-native."

Dev: "Do I need to await document edits?"

Domain expert: "No. The Document Handle is synchronous; concurrency is mediated by closure-scoped transactions."

Dev: "Which object unregisters a text observer?"

Domain expert: "The Observation owns that subscription. An Event Stream may use one internally, but the native lifetime belongs to the Observation."

Dev: "Does the Signaling Server ever see the document updates?"

Domain expert: "No. It only relays Peer Signals so peers in a Room can find each other. Sync and awareness travel directly over the Mesh Topology's data channels."

Dev: "Is the Room a different thing from the document name?"

Domain expert: "No. The Room is the WebRTC transport's name for one shared document; it is the same string the provider uses as the document name."
