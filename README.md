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
let observation = try awareness.observe { event in
    let states = try? awareness.clientStates()
    print("online clients:", states?.count ?? 0)
}
```

### Sync protocol (y-protocols)

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

Type a message and press Enter to send it; it appears on every peer's screen.
Use `/quit` (or Ctrl-C) to leave — both tear down the connection cleanly before
exiting.

Options (all optional):

| Flag | Default | Description |
|---|---|---|
| `--name <string>` | prompt, then `user-<uuid>` | Sender name shown on each message |
| `--room <string>` | `chat-demo` | Room to join; peers in the same room see each other |
| `--signaling <url>` | `ws://127.0.0.1:4444` | Signaling server URL; comma-separated and repeatable |
| `--password <string>` | none | Optional shared-room password (encrypts signaling) |

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
| Subdocuments | ✅ | ✅ | ✅ | Nested `YDoc` via `setNewSubdoc`, `loadSubdoc`, `clearSubdoc` |
| Observers (callback) | ✅ | ✅ | ✅ | `Observation` token, per-type `.observe(_:)` |
| Observers (async stream) | ✅ | ✅ | ✅ | `.events()` returns `AsyncStream<YEvent>` |
| Document update observers | ✅ | ✅ | ✅ | `observeUpdates`, `observeTransactionCleanup`, `observeSubdocs`, `observeDestroy` |
| Transaction origins | ✅ | ✅ | ✅ | `doc.write(origin:)` |
| Encode state as update (v1) | ✅ | ✅ | ✅ | `encodeStateAsUpdateV1(from:)` |
| Encode state as update (v2) | ✅ | ✅ | ✅ | `encodeStateAsUpdateV2(from:)` |
| Apply update (v1 / v2) | ✅ | ✅ | ✅ | `apply(_:)` — encoding inferred from `YUpdate.encoding` |
| State vector | ✅ | ✅ | ✅ | `YStateVector` |
| Snapshots | ✅ | ✅ | ✅ | `YSnapshot`, `encodeStateFromSnapshot` |
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

This writes `Artifacts/YrsBridge.xcframework.zip` and its SwiftPM checksum. Upload both to the GitHub release and update the `binaryTarget` URL in the release `Package.swift`.

---

## License

MIT. See [LICENSE](LICENSE).
