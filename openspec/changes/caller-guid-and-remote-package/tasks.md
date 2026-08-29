## 1. OpenSpec and contract

- [x] 1.1 Validate the proposal, design, and capability specs with OpenSpec
- [x] 1.2 Add public API and error-contract tests for caller GUID, duplicate/invalid input, and unchanged auto creation

## 2. Caller GUID vertical slices

- [x] 2.1 Add shim statuses and a Rust test/implementation that parses a UUID and inserts a subdocument with `Options.guid`
- [x] 2.2 Expose the C declaration and Swift `setNewSubdoc(guid:forKey:in:)` API with typed error translation
- [x] 2.3 Add SQLite reconstruction coverage using the caller GUID as `documentName`
- [x] 2.4 Add Swift replica and Yjs interop coverage for caller-GUID parent and subdocument updates
- [x] 2.5 Refactor shared auto/caller insertion code and verify the existing auto-GUID path

## 3. Remote binary package

- [x] 3.1 Add default remote URL/checksum binary target and `SWIFTYRS_USE_LOCAL_ARTIFACT=1` contributor switch
- [x] 3.2 Update the binary consumer fixture and verification script to build from the tagged remote package with no local artifact
- [x] 3.3 Add release packaging/update script and tag-triggered CI upload workflow
- [x] 3.4 Document remote consumption, local source builds, checksum updates, and release steps

## 4. Verification and release

- [ ] 4.1 Run Swift, Rust, fixture, and clean-consumer tests; resolve failures
- [x] 4.2 Request and address code review findings
- [ ] 4.3 Build the final XCFramework, set the `v0.6.0` URL/checksum, create and publish the release tag and assets
