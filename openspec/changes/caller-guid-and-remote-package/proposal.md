## Why

The wiki app currently maintains a page UUID and a separate Yrs subdocument GUID, even though the page UUID is already the durable identity it needs for SQLite and CloudKit. SwiftPM consumers also cannot resolve the package from GitHub because the Apple FFI target points at a gitignored local XCFramework.

## What Changes

- Add a caller-GUID subdocument creation API alongside the existing auto-GUID API.
- Validate caller GUIDs at the Rust shim boundary and expose duplicate and invalid-GUID failures as typed Swift errors without panics.
- Preserve the existing automatic subdocument GUID path and Yjs wire compatibility.
- Change the Apple SwiftPM binary target to resolve a tagged GitHub release by URL and checksum, with an explicit local-artifact switch for contributors.
- Add release automation that builds, verifies, uploads, and records the XCFramework artifact and checksum for a tag.
- Document remote consumption, local development, and release steps.

## Capabilities

### New Capabilities

- `caller-guid-subdocuments`: Caller-selected, validated subdocument GUID creation and persistence/replication behavior.
- `remote-binary-package`: Tagged GitHub binary-artifact consumption and reproducible release workflow.

### Modified Capabilities

- `subdocuments`: Extend subdocument creation requirements with caller-selected GUIDs and typed validation errors.

## Impact

The Rust shim and C header gain a creation function using `yrs::Options.guid`; Swift gains a new transaction method and `YError` cases. Swift tests cover local creation, duplicate/invalid input, SQLite reconstruction, Swift/Yjs replication, and the unchanged auto path. `Package.swift`, release scripts/workflows, the binary consumer fixture, README, feature coverage, and OpenSpec specs are updated. The next release is `v0.6.0`.
