# SwiftYrs

Swift binding for [Yrs](https://github.com/y-crdt/y-crdt), which is a port of the [Yjs framework](https://yjs.dev/).

## Consuming a Release

Downstream SwiftPM consumers should use a tagged release that includes `YrsBridge.xcframework.zip` and its checksum. The binary artifact avoids requiring app developers to build Rust locally.

The release manifest should point `YrsBridgeFFI` at the uploaded artifact URL:

```swift
.binaryTarget(
    name: "YrsBridgeFFI",
    url: "https://github.com/siuying/SwiftYrs/releases/download/swift-yjs-0.1.0/YrsBridge.xcframework.zip",
    checksum: "<checksum from YrsBridge.xcframework.zip.checksum>"
)
```

SwiftPM packages that are consumed directly from Git must still use semantic version tags such as `0.1.0`. The `swift-yjs-*` workflow tags are for producing monorepo release assets; mirror or publish the Swift package with semantic tags when exposing it as a direct SwiftPM dependency.

Create the release ZIP and checksum from the repository root with:

```sh
scripts/package-binary-artifact.sh
```

The script builds the XCFramework for arm64 macOS, arm64 iOS device, and arm64 iOS simulator, writes `Artifacts/YrsBridge.xcframework.zip`, and writes the SwiftPM checksum to `Artifacts/YrsBridge.xcframework.zip.checksum`.

The GitHub Actions workflow `SwiftYrs Binary Artifact` runs the same packaging path for `swift-yjs-*` tags and manual dispatches. Tag builds upload the ZIP and checksum to the GitHub release.

## Contributor Development

Prerequisites:

- Xcode with Swift 6 and `xcodebuild`
- Rust with the Initial Apple Matrix targets:
  - `aarch64-apple-darwin`
  - `aarch64-apple-ios`
  - `aarch64-apple-ios-sim`

Install missing Rust targets with:

```sh
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim
```

Build the local development artifact:

```sh
./scripts/build-xcframework.sh
```

The script produces `Artifacts/YrsBridge.xcframework`, which `Package.swift` imports as the local `YrsBridgeFFI` binary target. This local vendoring path is for contributors working on the binding; it keeps the Rust bridge editable and avoids needing a release artifact for each API iteration.

Run the Swift package tests after building the XCFramework:

```sh
swift test
```

Validate the consumer-style binary target fixture after building the XCFramework:

```sh
./scripts/verify-binary-consumer.sh
```

Regenerate checked-in JavaScript Yjs interop fixtures from the repository root with:

```sh
bun i
bun scripts/generate-yjs-fixtures.mjs
```
