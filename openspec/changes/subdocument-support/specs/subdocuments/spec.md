## ADDED Requirements

### Requirement: A subdocument SHALL be accessible as a full document

The API SHALL return the subdocument stored at a map key as a `YDoc`. The
API SHALL also return the subdocument for a known GUID within a
transaction. The returned document SHALL support every `YDoc` operation:
transactions, shared types, update encoding and apply, observation, and
undo. A key or GUID that does not name a subdocument SHALL produce a typed
error.

#### Scenario: Open a subdocument by key

- **WHEN** a map holds a subdocument at key `"page"` and the caller asks
  for the document at that key
- **THEN** the caller receives a `YDoc` whose GUID equals the stored
  subdocument's GUID, and a text written through it is readable through a
  second handle to the same subdocument

#### Scenario: Open a subdocument by GUID

- **WHEN** the caller asks a transaction for the subdocument with a GUID
  that the document tree holds
- **THEN** the caller receives a `YDoc` with that GUID

#### Scenario: Ask for a value that is not a subdocument

- **WHEN** the caller asks for a subdocument at a key that holds a string
- **THEN** the call throws a type-mismatch error

### Requirement: Parent and subdocument update streams SHALL be independent

An edit inside a subdocument SHALL NOT appear in the parent document's
update stream. An edit in the parent SHALL NOT appear in the subdocument's
update stream. The subdocument SHALL have its own state vector and its own
client ID.

#### Scenario: Edit the subdocument

- **WHEN** an observer watches the parent's updates and the caller writes
  text inside a subdocument
- **THEN** the parent observer receives no update, and an observer on the
  subdocument receives one

#### Scenario: Edit the parent

- **WHEN** an observer watches the subdocument's updates and the caller
  writes a value into a parent map
- **THEN** the subdocument observer receives no update

### Requirement: A parent update SHALL materialise the subdocument entry on a remote replica

Applying a parent update that contains a subdocument entry SHALL create the
entry with the same GUID on the receiving document. The receiver SHALL be
able to open the subdocument and apply the subdocument's own updates to it.

#### Scenario: Replicate a subdocument between two SwiftYrs documents

- **WHEN** replica A creates a subdocument with text, and replica B applies
  A's parent update and then the subdocument's update
- **THEN** B opens the subdocument by the same GUID and reads the text

#### Scenario: Read a Yjs-made subdocument

- **WHEN** a fixture update made by Yjs holds a map with a subdocument
- **THEN** SwiftYrs applies it, lists the same GUID, and opens the
  subdocument

### Requirement: Clearing a subdocument SHALL follow yrs destroy semantics

`clearSubdoc` SHALL destroy the subdocument instance, following yrs: the
destroy observers fire, the instance detaches from the parent, and the
parent entry SHALL remain as a fresh, unloaded subdocument reference with
the same GUID. A held handle SHALL stay safe: a write through it SHALL NOT
crash and SHALL NOT reach the parent or any replica. Releasing the handle
after the clear SHALL be safe in any order.

#### Scenario: Use a handle after clear

- **WHEN** the caller holds a subdocument `YDoc`, clears the subdocument in
  the parent, and then writes through the held handle
- **THEN** nothing crashes, the parent document does not change, and
  releasing the handle later is safe

#### Scenario: Observe the clear

- **WHEN** the caller observes the subdocument's destroy event and the
  parent's subdocument events, and then clears the subdocument
- **THEN** the destroy observer fires, and the parent still lists an entry
  with the same GUID, not loaded

### Requirement: A database provider SHALL persist a subdocument

`SQLiteProvider` SHALL persist and reconstruct a subdocument `YDoc` with
the subdocument GUID as `documentName`, in the same `SQLiteStore` as the
parent document, with no provider code change.

#### Scenario: Reconstruct a subdocument from the store

- **WHEN** a provider persists a parent and a second provider persists its
  subdocument, the app restarts, and both providers start again on fresh
  documents
- **THEN** the parent holds the subdocument entry, and the subdocument
  holds its text
