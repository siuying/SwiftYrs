## Context

`yrs` 0.27 exposes `Options.guid: Uuid`, and `Doc::with_options` is already used by the shim for Yjs-compatible offset options. The existing map insertion helper always inserts `new_doc()`, so the Swift caller cannot reuse its page UUID. Existing Swift error translation has stable numeric codes and `YError` cases, while the current Apple manifest requires `Artifacts/YrsBridge.xcframework`, which is generated and gitignored.

## Goals / Non-Goals

**Goals:**

- Make caller-selected GUID creation a safe, public Swift operation.
- Reject malformed GUIDs and GUIDs already registered in the parent transaction with typed errors.
- Keep automatic creation, update encoding, SQLite document names, and Yjs interop unchanged.
- Make the default Apple package resolvable from a GitHub release and retain an explicit source-build path.
- Have tag-driven automation produce and publish the exact artifact referenced by that tag.

**Non-Goals:**

- Changing GUID format, subdocument map conflict semantics, providers, CloudKit routing, or Yjs protocol encoding.
- Removing local XCFramework development support.
- Supporting arbitrary existing `YDoc` insertion as a subdocument.

## Decisions

1. **Parse GUIDs in the shim with `uuid::Uuid`.** Construct `Options` from the existing Yjs-compatible defaults, set `options.guid`, and call `Doc::with_options`. Invalid input returns a dedicated invalid-GUID status. This keeps UUID canonicalization and validation in the same layer as Yrs; accepting arbitrary strings would not match `yrs`'s UUID-backed GUID model.

2. **Detect duplicate GUIDs before insertion.** Inspect the parent transaction's registered subdocuments and return a dedicated duplicate status before invoking `MapRef::insert`. This prevents ambiguous GUID lookup and avoids relying on Yrs's panic-prone prelim path. The existing map-key replacement behavior remains unchanged for distinct GUIDs.

3. **Keep the old helper as a compatibility path.** `setNewSubdoc(forKey:in:)` continues to generate a random GUID and delegates to the same insertion implementation. The new Swift method is `setNewSubdoc(guid:forKey:in:)`.

4. **Use a manifest environment switch for Apple artifacts.** Default to a URL binary target pointing at the release tag's `YrsBridge.xcframework.zip`; when `SWIFTYRS_USE_LOCAL_ARTIFACT=1`, select the existing local path target. This makes downstream resolution deterministic while contributors can build from source without editing the manifest.

5. **Use tag-driven GitHub Actions for releases.** The workflow builds the XCFramework, computes its SwiftPM checksum, verifies a clean binary consumer, uploads the ZIP/checksum, and attaches them to the GitHub release. A release script updates the URL/checksum in the checked-out manifest for the tag before the release commit/tag is created; CI verifies the committed values match the generated artifact.

## Risks / Trade-offs

- **UUID spelling changes:** `Uuid::parse_str` accepts common UUID spellings but Yrs stores the canonical hyphenated lowercase string. Tests assert the reported canonical value. → Document canonicalization.
- **Duplicate detection and concurrent transactions:** The check is scoped to the parent transaction, matching Yrs's transaction model. → Test duplicate creation in one writable transaction and ensure no native panic reaches Swift.
- **Remote artifact availability:** A manifest pointing at a future tag cannot resolve until its release asset exists. → Build and publish the asset before announcing the tag; verify from a clean consumer with no `Artifacts` directory.
- **Environment-dependent manifest behavior:** Local mode is intentionally opt-in and Apple-only. → Keep Linux source build unchanged and document the variable and command.

## Migration Plan

1. Add the OpenSpec contract and tests.
2. Implement shim status codes, Swift API, package/release workflow, and docs.
3. Build the Apple XCFramework, compute checksum, set the `v0.6.0` manifest URL/checksum, and run the clean consumer verification.
4. Commit the release-ready changes, create/push `v0.6.0`, and publish the GitHub release with the ZIP and checksum. Do not merge to `main`.

Rollback is deleting the tag/release and reverting the package manifest to the previous release; the old auto-GUID API remains source-compatible.

## Open Questions

- GitHub release publishing depends on the configured `gh` credentials and repository permissions; if unavailable, report the exact blocker rather than claiming publication.
