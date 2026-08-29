## ADDED Requirements

### Requirement: Apple consumers SHALL resolve the tagged binary remotely

The default Apple `Package.swift` manifest SHALL use a URL binary target for the `YrsBridge.xcframework.zip` asset of the package's release tag and its exact SwiftPM checksum. A clean consumer SHALL resolve and build without a local checkout or `Artifacts` directory.

#### Scenario: Resolve a tagged release

- **WHEN** a downstream app depends on the tagged SwiftYrs package
- **THEN** SwiftPM downloads the release XCFramework and builds without local native artifacts

### Requirement: Contributors SHALL have a documented local-artifact path

Contributors SHALL be able to opt into the local XCFramework path with a documented environment switch after building from source. Linux source builds SHALL remain supported.

#### Scenario: Build with a local artifact

- **WHEN** a contributor builds the XCFramework and sets the documented local-artifact switch
- **THEN** SwiftPM uses `Artifacts/YrsBridge.xcframework` and the package's tests build without downloading the release binary

### Requirement: A release SHALL build and publish its binary artifact

The release script or CI job SHALL build the supported XCFramework slices, compute the SwiftPM checksum, verify the binary consumer without a local checkout, and attach the ZIP and checksum to the corresponding GitHub release. README SHALL document these steps and the exact consumer dependency form.

#### Scenario: Publish a tagged artifact

- **WHEN** the release workflow runs for a version tag
- **THEN** it uploads the checksumed XCFramework ZIP and checksum to that tag's GitHub release after the clean consumer verification passes
