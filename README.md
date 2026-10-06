# SwiftYrs

Swift binding for [Yrs](https://github.com/y-crdt/y-crdt), the Rust port of the [Yjs](https://yjs.dev/) CRDT framework. SwiftYrs lets you build collaborative, offline-first iOS, macOS, and Linux apps with the same wire-compatible protocol as Yjs.

- **Platforms**: macOS 14+, iOS 17+ (arm64), Linux (x86_64 / arm64)
- **Swift**: Swift 6, SwiftPM only
- **Wire compatibility**: binary-compatible with Yjs 13.x updates, state vectors, snapshots, and y-protocols sync messages

---

## Project Organization

```
SwiftYrs/
├── Sources/SwiftYrs/          # Swift 6 public API
│   ├── YDoc.swift             # YDoc, YReadTransaction, YWriteTransaction, YUpdate, YStateVector
│   ├── YSharedTypes.swift     # YSharedType base class; YText, YMap, YArray, YXmlFragment/Element/Text, YValue
│   ├── YEvent.swift           # YEvent, YSharedEvent, YAwarenessChange — typed observation events
│   ├── YObservation.swift     # Observation, AsyncStream bridges, document observers
│   ├── YAwareness.swift       # YAwareness, YAwarenessUpdate, awareness observers
│   ├── YSync.swift            # YSyncMessage — encode/decode y-protocols messages
│   ├── YUndoManager.swift     # YUndoManager — undo/redo with origin filtering
│   └── YWeakLinks.swift       # YWeakLink, YRelativePosition (sticky indexes)
├── Sources/SwiftYrsWebRTC/    # WebRTC transport (Apple platforms only)
│   ├── WebRTCProvider.swift   # WebRTCProvider actor — y-webrtc-compatible mesh sync
│   ├── SignalingConnection.swift # WebSocket signaling client
│   └── ...                    # Peer signaling, ICE, cipher, codec helpers
├── Sources/SwiftYrsHocuspocus/ # Hocuspocus WebSocket provider
│   ├── HocuspocusProvider.swift # HocuspocusProvider actor — syncs a YDoc over y-protocols WebSocket
│   └── ...                    # Message codec, auth helpers
├── Sources/ChatExample/       # Runnable terminal chat (Apple platforms only)
│   ├── ChatExample.swift      # Entry point — CLI arg parsing, peer lifecycle
│   ├── ChatLog.swift          # Shared YArray-backed message log
│   └── ChatConfig.swift       # Room / signaling configuration
├── Tests/SwiftYrsTests/       # Swift test suite
│   ├── Fixtures/              # Cross-language JSON fixtures generated from Yjs
│   └── *.swift                # Per-feature test files
├── native/                    # Rust shim crate (YrsBridge) — exports the C ABI
├── Artifacts/                 # Built XCFramework (generated; not committed)
├── scripts/
│   ├── build-xcframework.sh          # Build Artifacts/YrsBridge.xcframework locally
│   ├── package-binary-artifact.sh    # Zip + checksum for a release
│   ├── verify-binary-consumer.sh     # Smoke-test downstream binary-target consumption
│   └── generate-yjs-fixtures.mjs    # Regenerate Fixtures/ from Yjs (requires Node.js)
├── docs/
│   └── feature-coverage.md    # Feature coverage matrix vs. y-crdt 0.27 / yffi
├── Package.swift              # SwiftPM package definition
└── CONTEXT.md                 # Domain language glossary for contributors
```

---

## Requirements

**Apple (macOS / iOS)**
- Xcode with Swift 6 and `xcodebuild`
- arm64 Mac (Apple Silicon) or arm64 iOS device / simulator

**Linux**
- Swift 6 toolchain
- Rust (stable) for building the native library from source

No Rust installation is required for Apple app developers — consume a tagged release that ships a pre-built XCFramework.

---

## How to Use

### Add the package (app developers)

Add SwiftYrs to your `Package.swift` using a release that includes the pre-built `YrsBridge.xcframework.zip`:

```swift
// Package.swift
let package = Package(
    dependencies: [
        .package(url: "https://github.com/siuying/SwiftYrs", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "SwiftYrs", package: "SwiftYrs"),
            ]
        ),
    ]
)
```

Apple consumers download the tagged XCFramework from GitHub. Contributors can
build locally and set `SWIFTYRS_USE_LOCAL_ARTIFACT=1` to use
`Artifacts/YrsBridge.xcframework` instead.

Or in Xcode: **File → Add Package Dependencies** and enter the repository URL.

### Build from source (contributors)

**Apple:**

Install the required Rust targets, build the XCFramework, then run the test suite:

```sh
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-xcframework.sh
swift test
```

**Linux:**

Build the native library and generate the pkg-config file, then run the test suite:

```sh
./scripts/build-linux.sh
export PKG_CONFIG_PATH="$PWD/Artifacts/linux/pkgconfig"
swift test
```

---

## Examples

### Collaborative text editing

```swift
import SwiftYrs

// Create a document
let doc = YDoc()

// Get a named shared text type
let text = try doc.text(named: "content")

// Write inside a transaction
try doc.write { txn in
    try txn.insert("Hello, world!", into: text, at: 0)
}

// Read back the string
let result = try doc.read { txn in
    try txn.string(from: text)
}
// result == "Hello, world!"
```

### Syncing two documents

```swift
let docA = YDoc()
let docB = YDoc()

let text = try docA.text(named: "notes")
try docA.write { txn in
    try txn.insert("Hello from A", into: text, at: 0)
}

// Encode the full state of A as an update
let update = try docA.encodeStateAsUpdateV1()

// Apply it to B — B now has the same content
try docB.apply(update)
```

### Observing changes

```swift
let doc = YDoc()
let text = try doc.text(named: "content")

// Callback-based. Events are a typed `YEvent` enum — switch on the case.
let observation = try text.observe { event in
    if case let .shared(change) = event {
        print("text changed, \(change.delta.count) delta ops")
    }
}
// Cancel when done
observation.cancel()

// AsyncStream (Swift concurrency)
let stream = try text.events()
Task {
    for await event in stream {
        if case let .shared(change) = event, change.target == .text {
            print("text event, \(change.delta.count) delta ops")
        }
    }
}
```

### Rich text with attributes

```swift
let doc = YDoc()
let text = try doc.text(named: "body")

try doc.write { txn in
    try txn.insert("bold text", into: text, at: 0, attributes: ["bold": .bool(true)])
    try txn.format(text, at: 0, length: 4, attributes: ["italic": .bool(true)])
}

let chunks = try doc.read { txn in try txn.chunks(from: text) }
// chunks[0].attributes == ["bold": .bool(true), "italic": .bool(true)]
```

### YMap

```swift
let doc = YDoc()
let map = try doc.map(named: "metadata")

try doc.write { txn in
    try txn.set(.string("Alice"), forKey: "author", in: map)
    try txn.set(.int(42), forKey: "version", in: map)
}

let author = try doc.read { txn in try txn.get("author", from: map) }
// author == .string("Alice")
```

### YArray

```swift
let doc = YDoc()
let array = try doc.array(named: "items")

try doc.write { txn in
    try txn.insert(.string("first"), into: array, at: 0)
    try txn.insert(.string("second"), into: array, at: 1)
}

let count = try doc.read { txn in try txn.count(of: array) }
// count == 2
```

### Undo / Redo

```swift
let doc = YDoc()
let text = try doc.text(named: "content")
let undoManager = YUndoManager(document: doc)
try undoManager.addScope(text)

try doc.write { txn in
    try txn.insert("Hello", into: text, at: 0)
}

try undoManager.undo()  // removes "Hello"
try undoManager.redo()  // restores "Hello"
```

### Awareness (presence / cursors)

Awareness starts with a null local state. Set a non-null state before connecting to Hocuspocus, even `[:]`, to keep an idle connection alive through awareness renewals. Null or disabled awareness sends no renewals, so an idle Hocuspocus server may close the connection with code 4408. The default remains null; use `clearLocalState()` to return to it.

`observeUpdate` and `observeChange` deliver callbacks serially outside the awareness lock. Nested events are delivered breadth-first; JavaScript delivers them depth-first. State updates happen immediately, but delivery may be delayed or run on another thread, so callbacks should read current state. A callback must not wait for a thread that is waiting for its own awareness events.

```swift
let doc = YDoc()
let awareness = YAwareness(document: doc)

// Set local user state
try awareness.setLocalState(["name": "Alice", "cursor": 42])

// Encode and ship to peers
let update = try awareness.encodeUpdate()

// Apply an update received from a peer
let remoteAwareness = YAwareness(document: doc)
try remoteAwareness.applyUpdate(update)

// Observe state changes
let observation = try awareness.observeChange { event in
    let states = try? awareness.states()
    print("online clients:", states?.count ?? 0)
}
```

### Hocuspocus

`HocuspocusProvider` syncs one document over a Hocuspocus WebSocket. `disconnect()` is temporary: it closes the socket immediately, discards queued messages and keeps local awareness, so `connect()` can resume with the same presence. When the session ends, await `destroy()` instead. It clears local awareness, even when it is already null, and stops processing inbound messages. It then waits up to 5 seconds for queued messages and that final awareness update to be handed to the socket, then closes the socket and finishes the event streams. If the socket is stuck, it drops the remaining messages at the deadline instead of hanging. This is an awaited write attempt. It does not confirm that the server or peers applied the update; the server may still report the departure through its own cleanup of the closed connection. Concurrent calls wait for the same teardown. Later calls do nothing, and a destroyed provider cannot reconnect.

`sendStateless(_:)` returns after its message is written to the socket, or after the connection drops it. While a slow socket has writes pending, queued awareness updates are coalesced to the latest state. If more than 1024 messages are waiting, the provider drops the queue and reconnects; sync on reconnect restores document state.

Incoming WebSocket messages may be up to `maximumMessageSize` bytes, 64 MiB by default; `URLSessionWebSocketTask` alone allows only 1 MiB, which the first sync of a large document exceeds. If the server sends a larger message, the provider yields `HocuspocusProviderError.messageTooLarge(limit:)` on `errors` and disconnects without reconnecting, because the same sync would fail again.

```swift
let provider = HocuspocusProvider(url: url, name: "room", document: doc, awareness: awareness)
try await provider.connect()
// ...
await provider.destroy()
```

### Sync protocol (y-protocols)

`YSyncProtocol.start(awareness:)` and `handle(_:awareness:)` synchronously wait for document contention with a 5 ms retry delay and a one-second deadline per document operation. Only `YError.transactionConflict` is retried; other errors propagate immediately. Calls made inside a transaction or its commit observer can prevent that transaction from finishing, so they throw `transactionConflict` at the deadline instead of hanging. Awareness access stays synchronized independently; retries never hold the awareness lock.

Custom providers can use `handle(_:awareness:origin:)` to tag inbound awareness events with a provider-specific origin and suppress their echoes. For example, `try YSyncProtocol.handle(receivedData, awareness: awareness, origin: providerOrigin)` returns the response payload. The origin applies to awareness events, not document updates.

`handle` decodes the entire batched payload before applying messages. A malformed later protocol message rejects the batch without applying earlier messages, whereas the native handler applied the valid prefix first. Errors during application do not roll back earlier messages.

```swift
// Initiating sync (client → server)
let stateVector = try doc.stateVector()
let step1 = try YSyncMessage.syncStep1(stateVector)
send(step1.payload)

// Responding to sync step 1 (server → client)
let update = try doc.encodeStateAsUpdateV1(from: receivedStateVector)
let step2 = try YSyncMessage.syncStep2(update)
send(step2.payload)

// Decode incoming messages
let messages = try YSyncMessage.decodePayload(receivedData)
for message in messages {
    switch message {
    case let .syncStep2(update, _):
        try doc.apply(update)
    case let .update(update, _):
        try doc.apply(update)
    default:
        break
    }
}
```

### Sticky indexes (relative positions)

```swift
let doc = YDoc()
let text = try doc.text(named: "content")

try doc.write { txn in
    try txn.insert("Hello world", into: text, at: 0)
}

// Capture a position that survives remote edits
let position = try doc.read { txn in
    try txn.relativePosition(in: text, at: 5, association: .after)
}

// Resolve it after more edits
try doc.write { txn in
    try txn.insert("!!", into: text, at: 0)
}

let resolved = try doc.read { txn in
    try txn.absolutePosition(of: position, in: text)
}
// resolved.index == 7  (shifted by the 2 inserted chars)
```

### Subdocuments

A subdocument is a document nested in a parent's map — the shape behind a
lazily-loaded wiki page or a folder of notes. `subdocDoc(forKey:in:)` returns
it as a plain `YDoc`, so every document API applies to it.

```swift
let vault = YDoc()
let pages = try vault.map(named: "pages")
let pageID = UUID().uuidString

// Create the entry; the parent stores a reference (a GUID), not the content.
let page = try vault.write { txn in
    try txn.setNewSubdoc(guid: pageID.uuidString, forKey: "home", in: pages)
}

// Open the subdocument itself, by key or by the GUID you stored.
let pageDoc = try vault.read { try $0.subdocDoc(forKey: "home", in: pages) }
let sameDoc = try vault.read { try $0.subdocDoc(guid: page.guid) }

let body = try pageDoc.text(named: "body")
try pageDoc.write { txn in
    try txn.insert("Welcome", into: body, at: 0)
}
```

A parent's update stream never carries subdocument content. The parent update
replicates the entry (same GUID on every replica); the body travels in the
subdocument's own updates, with its own state vector. So each subdocument needs
its own provider, and its GUID is the natural document name:

```swift
let store = try SQLiteStore(Connection(path))
let vaultProvider = SQLiteProvider(documentName: "vault", doc: vault, store: store)
try vaultProvider.start()

// Lazy open: start the page's provider when the user opens the page,
// and destroy it when the page closes.
let pageProvider = SQLiteProvider(documentName: page.guid, doc: pageDoc, store: store)
try pageProvider.start()
defer { pageProvider.destroy() }
```

Two further rules, both inherited from yrs and Yjs:

- `clearSubdoc(forKey:in:)` destroys the instance and fires its destroy
  observers, but keeps the parent entry as an unloaded reference with the same
  GUID. A handle held across the clear stays safe to use and to release; writes
  through it reach nobody.
- Two replicas that each call `setNewSubdoc` for one logical page create two
  GUIDs and race on the map key. Create a subdocument once, on one replica.

### CloudKit sync

`SwiftYrsCloudKit` syncs documents across one iCloud user's devices through a
single `CKSyncEngine`. A `CloudKitSyncStore` owns that engine and one CloudKit
zone; every document you sync through the store lives in that zone, so a vault
of a hundred pages costs one zone, one change token, and one fetch — not a
hundred. You name the zone (ADR-0025):

```swift
let store = CloudKitSyncStore(
    adapter: CKSyncEngineAdapter(containerIdentifier: "iCloud.com.example.Wiki"),
    // One store per vault; the zone carries the vault's identity.
    codec: try CloudKitRecordCodec(zoneName: vaultID.uuidString, assetDirectory: assets),
    metadataStore: FileCloudKitMetadataStore(directory: metadata)
)
await store.start()

// The vault's root document opens with the vault.
let rootProvider = try CloudKitProvider(documentName: "root", doc: vault, store: store)
try await rootProvider.start()
```

Page providers start lazily, when the user opens a page, and are destroyed when
it closes. Remote edits that arrive while a page is closed are not lost: the
store spools them, persistently, and replays them in arrival order when that
page's provider starts.

```swift
let pageProvider = try CloudKitProvider(documentName: page.guid, doc: pageDoc, store: store)
try await pageProvider.start()   // applies anything spooled for this page first
defer { Task { await pageProvider.destroy() } }
```

Removal comes at two grains:

```swift
// One document. Best-effort: it deletes the records the store recorded, and
// anything it missed is collected by the next snapshot cycle's GC.
try await store.removeDocument(named: page.guid)

// The whole dataset — every document in the zone. Exact.
try await store.removeZone()
```

Both throw while a provider is still attached, so destroy providers first.

> **Breaking change.** Earlier versions put each document in its own zone and
> `CloudKitRecordCodec` took no zone name. `CloudKitRecordCodec(zoneName:...)`
> is now required, `zoneID(forDocumentName:)` is gone, and record names carry
> their document. Records written under the old mapping are not readable — the
> first sync after upgrading re-seeds the zone from the local document, which is
> untouched.

### Terminal chat

`ChatExample` is a runnable command-line chat that demonstrates `SwiftYrsWebRTC`
end to end. Peers join a WebRTC mesh through a local signaling server and
collaborate on a single shared `YDoc`. Each line you type appends a message that
syncs to every connected peer; a newly joining peer syncs the full history and
shows the last 10 messages, then streams new ones as they arrive. (Apple
platforms only — the example is gated to the non-Linux build.)

First, start the signaling server (it prints its `ws://` URL on startup and
listens on a fixed port, `ws://127.0.0.1:4444`):

```sh
npm install                              # once, to fetch the `ws` dependency
node Examples/chat-signaling-server.ts
```

Then run `ChatExample` in two or more terminals, giving each a name:

```sh
swift run ChatExample --name alice
swift run ChatExample --name bob
```

To keep local chat history across restarts, pass a SQLite database path:

```sh
swift run ChatExample --name alice --database /tmp/swiftyrs-chat.sqlite
```

Type a message and press Enter to send it; it appears on every peer's screen.
Use `/quit` (or Ctrl-C) to leave — both tear down the connection cleanly before
exiting.

When `--database` is present, the example starts `SQLiteProvider` before
connecting WebRTC, using the room name as the SQLite document name. Restarting
with the same `--room` and database path replays local history before network
sync completes. Manual verification: run the example with `--database`, send a
message, quit, then run the same command again and confirm the message appears
in the initial history.

Options (all optional):

| Flag | Default | Description |
|---|---|---|
| `--name <string>` | prompt, then `user-<uuid>` | Sender name shown on each message |
| `--room <string>` | `chat-demo` | Room to join; peers in the same room see each other |
| `--signaling <url>` | `ws://127.0.0.1:4444` | Signaling server URL; comma-separated and repeatable |
| `--password <string>` | none | Optional shared-room password (encrypts signaling) |
| `--database <path>` | none | SQLite database path for local persistence |

---

## Feature Parity

The table below maps Yjs 13.6 public API surface to SwiftYrs. The Yrs/yffi column reflects the upstream Rust library version bundled in this release (y-crdt 0.27).

| Feature | Yjs 13.6 | Yrs/yffi 0.27 | SwiftYrs | Notes |
|---|---|---|---|---|
| `Y.Doc` | ✅ | ✅ | ✅ | `YDoc` with `read`/`write` transaction closures |
| Client ID | ✅ | ✅ | ✅ | `YDoc(clientID:)` |
| `Y.Text` insert / delete | ✅ | ✅ | ✅ | `YWriteTransaction.insert(_:into:at:)` / `.remove(from:at:length:)` |
| `Y.Text` formatting attributes | ✅ | ✅ | ✅ | `format(_:at:length:attributes:)` |
| `Y.Text` delta input / output | ✅ | ✅ | ✅ | `applyDelta(_:to:)` / `delta(from:)` |
| `Y.Text` embeds | ✅ | ✅ | ✅ | `insertEmbed(_:into:at:attributes:)` |
| `Y.Map` get / set / delete | ✅ | ✅ | ✅ | `set(_:forKey:in:)` / `remove(_:from:)` / `get(_:from:)` |
| `Y.Map` weak links | ✅ | ✅ | ✅ | `YWeakLink`, `YMap` link/deref APIs |
| `Y.Array` insert / delete | ✅ | ✅ | ✅ | `insert(_:into:at:)` / `remove(from:at:length:)` |
| `Y.Array` / `Y.Text` quotations | ✅ | ✅ | ✅ | Weak-range quote APIs |
| `Y.Array` move | ✅ | ❌ removed | ❌ | Removed in y-crdt ; [see](https://www.bartoszsypytkowski.com/replacing-yjs-move-feature/) |
| `Y.XmlFragment` | ✅ | ✅ | ✅ | `YXmlFragment` child insert/remove/read |
| `Y.XmlElement` | ✅ | ✅ | ✅ | `YXmlElement` tag, attributes, children |
| `Y.XmlText` | ✅ | ✅ | ✅ | `YXmlText` insert/remove/attributes |
| Subdocuments | ✅ | ✅ | ✅ | `setNewSubdoc(guid:forKey:in:)` / `setNewSubdoc(guid:forKey:in:options:)` or auto-GUID `setNewSubdoc`, `subdocDoc(forKey:in:)` / `subdocDoc(guid:)`, `loadSubdoc`, `clearSubdoc`, `subdocGuids` |
| Observers (callback) | ✅ | ✅ | ✅ | `Observation` token, per-type `.observe(_:)` |
| Observers (async stream) | ✅ | ✅ | ✅ | `.events()` returns `AsyncStream<YEvent>` |
| Document update observers | ✅ | ✅ | ✅ | `observeUpdates`, `observeTransactionCleanup`, `observeSubdocs`, `observeDestroy` |
| Transaction origins | ✅ | ✅ | ✅ | `doc.write(origin:)` |
| Encode state as update (v1) | ✅ | ✅ | ✅ | `encodeStateAsUpdateV1(from:)` |
| Encode state as update (v2) | ✅ | ✅ | ✅ | `encodeStateAsUpdateV2(from:)` |
| Apply update (v1 / v2) | ✅ | ✅ | ✅ | `apply(_:)` — encoding inferred from `YUpdate.encoding` |
| State vector | ✅ | ✅ | ✅ | `YStateVector` |
| Snapshots | ✅ | ✅ | ✅ | `YDoc.Options`, `YDoc.options`, `YReadTransaction.snapshot()`, `YSnapshot.encode()/decode(_:)`, `encodeStateFromSnapshotV1/V2` (state-from-snapshot requires `YDoc.Options(skipGC: true)`) |
| Sticky indexes / relative positions | ✅ | ✅ | ✅ | `YRelativePosition`, `relativePosition(in:at:association:)` / `absolutePosition(of:in:)` |
| Undo Manager | ✅ | ✅ | ✅ | `YUndoManager` with scope, origin include/exclude, undo/redo stacks |
| Awareness | ✅ | ✅ (shim) | ✅ | `YAwareness`, `YAwarenessUpdate` — implemented via project-owned Rust shim |
| Sync protocol messages | ✅ | ✅ (shim) | ✅ | `YSyncMessage` encode/decode — syncStep1/2, update, awareness, auth — via Rust shim |
| Recursive nesting | ✅ | ✅ | ✅ | `YValue` enum covers all shared-type variants |

---

## Contributing

### Build the native library

**Apple** — prerequisites: Xcode (Swift 6), Rust with the arm64 Apple targets:

```sh
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
./scripts/build-xcframework.sh
swift test
```

**Linux** — prerequisites: Swift 6 toolchain, Rust (stable):

```sh
./scripts/build-linux.sh
export PKG_CONFIG_PATH="$PWD/Artifacts/linux/pkgconfig"
swift test
```

### Regenerate interop fixtures

The `Tests/SwiftYrsTests/Fixtures/` JSON files are generated from JavaScript Yjs and checked in. Regenerate them after changing fixture logic:

```sh
npm install
node scripts/generate-yjs-fixtures.mjs
```

### Release a binary artifact

```sh
scripts/package-binary-artifact.sh
```

This writes `Artifacts/YrsBridge.xcframework.zip` and its SwiftPM checksum.
Run `scripts/release-binary-artifact.sh 0.6.0` before creating the tag; it
updates the URL and checksum in `Package.swift`. The tag workflow rebuilds the
artifact, verifies the clean binary consumer, and uploads the ZIP and checksum
to the GitHub release. Do not commit `Artifacts/`.

---

## License

MIT. See [LICENSE](LICENSE).
