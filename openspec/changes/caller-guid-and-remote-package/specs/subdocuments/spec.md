## ADDED Requirements

### Requirement: A caller SHALL be able to choose a subdocument GUID

The API SHALL create a new map subdocument using a caller-provided UUID GUID. The resulting `YSubdoc` and opened `YDoc` SHALL report the canonical caller GUID, and the GUID SHALL survive parent-update replication and SQLiteProvider reconstruction when used as `documentName`.

#### Scenario: Create and open by caller GUID

- **WHEN** a writable transaction creates a subdocument with a valid caller GUID
- **THEN** the returned reference and the document opened by that GUID report the same canonical GUID

#### Scenario: Replicate a caller GUID

- **WHEN** replica A creates a caller-GUID subdocument and replica B applies A's parent update
- **THEN** B lists and opens the subdocument using that same GUID, and its own subdocument update remains wire-compatible with Yjs

### Requirement: Invalid or duplicate caller GUIDs SHALL be typed errors

Creating a subdocument with a malformed GUID SHALL throw `YError.invalidGUID`. Creating another subdocument with a GUID already registered in the parent SHALL throw `YError.duplicateSubdocGUID`. Neither failure SHALL crash, mutate the map, or insert a partially created subdocument.

#### Scenario: Reject invalid GUID

- **WHEN** the caller supplies a non-UUID GUID
- **THEN** creation throws `YError.invalidGUID` and the parent has no new subdocument

#### Scenario: Reject duplicate GUID

- **WHEN** the caller supplies a GUID already held by a subdocument in the parent
- **THEN** creation throws `YError.duplicateSubdocGUID` without a native panic

### Requirement: Automatic GUID creation SHALL remain compatible

The existing subdocument creation API SHALL continue to create a unique generated GUID and retain all existing map, replication, provider, and wire behavior.

#### Scenario: Create without a GUID

- **WHEN** the caller uses the existing creation method
- **THEN** creation succeeds with a generated GUID and existing callers need no changes
