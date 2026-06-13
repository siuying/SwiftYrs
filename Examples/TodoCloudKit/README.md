# TodoCloudKit example

A SwiftUI Todo app (iOS + macOS) that syncs across one iCloud user's devices
with **`SwiftYrsCloudKit`**, persisting locally with **`SwiftYrsSQLite`**.

Todos are modelled as a top-level `YArray("todos")` of nested
`YMap { id, title, completed }`. The same `YDoc` is wired to two providers:

- `SQLiteProvider` — local durability; reconstructs the document on launch.
- `CloudKitProvider` (over the real `CKSyncEngine` adapter) — propagates the
  document across the user's devices via their CloudKit private database.

`SQLiteProvider` starts **before** `CloudKitProvider`, so the document is
reconstructed before CloudKit's launch-time recovery drain runs.

## Generating the Xcode project

The project is generated with [XcodeGen](https://github.com/yonyz/XcodeGen)
from `project.yml` (a deliberate exception to the repo's "Node for tooling"
norm — a CLI target cannot carry iCloud entitlements, so this is a real signed
app project).

```sh
brew install xcodegen
cd Examples/TodoCloudKit
xcodegen generate
open TodoCloudKit.xcodeproj
```

The generated `TodoCloudKit.xcodeproj` is git-ignored — regenerate it from
`project.yml`.

## Running

1. In **Signing & Capabilities**, set your Apple Developer **Team** (or set
   `DEVELOPMENT_TEAM` in `project.yml`).
2. The app declares an iCloud **CloudKit** container
   (`iCloud.com.swiftyrs.TodoCloudKit`); change it to a container your team
   owns, and update `TodoCloudKit/TodoCloudKit.entitlements` to match.
3. Build and run on two devices/simulators signed into the **same** iCloud
   account, then add and complete todos — changes converge within the sync
   window. The toolbar icon reflects the synced state; signing out of iCloud
   surfaces a banner and stops syncing.
