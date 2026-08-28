## ADDED Requirements

### Requirement: A store SHALL keep every document in one caller-named zone

The codec SHALL require a zone name at construction, and every document of
the store SHALL live in that one zone. The store SHALL NOT create a zone
per document.

#### Scenario: Two documents in one zone

- **WHEN** providers for documents `a` and `b` on one store both send
  changes
- **THEN** every record of both documents lives in the one zone named at
  construction

#### Scenario: Two stores, two zones

- **WHEN** two stores are constructed with different zone names
- **THEN** their records live in different zones and neither store routes
  the other's records

### Requirement: A record name SHALL identify its document

Every record name SHALL begin with an encoded document component, and the
codec SHALL recover the document name from a record name alone. The
`documentName` record field SHALL stay, and decode SHALL fail with a typed
error when the name and the field disagree. A record name that does not
parse SHALL produce a typed error, never a route to another document.

#### Scenario: Route a deleted record

- **WHEN** the engine reports a deleted record ID
- **THEN** the store identifies the owning document from the record name
  alone and notifies that document's provider

#### Scenario: Name and field disagree

- **WHEN** a fetched record's name encodes document `a` and its field says
  document `b`
- **THEN** decode fails with a typed error and neither provider applies
  the record

### Requirement: The store SHALL dispatch engine callbacks per document

The store SHALL register providers by document name, SHALL group fetched
and sent callbacks by the document parsed from each record, and SHALL
answer record-to-save requests through the owning document's provider. A
provider SHALL receive only its own document's records.

#### Scenario: Interleaved fetches

- **WHEN** one fetched batch holds records of documents `a` and `b`
- **THEN** provider `a` receives only `a`'s records and provider `b`
  receives only `b`'s records

### Requirement: Fetched records without an active provider SHALL be spooled

The store SHALL persist fetched records and deletions whose document has
no registered provider. When that document's provider registers, the
store SHALL replay the spooled entries in arrival order through the
normal fetched path, then clear them. Spooled entries SHALL survive a
relaunch. When a snapshot record arrives for a document, spooled
incremental entries that the snapshot's state vector covers SHALL be
dropped.

#### Scenario: Remote edit to a closed page

- **WHEN** the engine fetches an update for document `p` while no provider
  for `p` is registered, and a provider for `p` registers later
- **THEN** the provider applies the spooled update and the document shows
  the remote edit

#### Scenario: Spool survives a relaunch

- **WHEN** an update is spooled, the process restarts, and the provider
  registers
- **THEN** the update still applies

#### Scenario: Snapshot coalesces the spool

- **WHEN** spooled incrementals for document `p` are covered by a fetched
  snapshot's state vector
- **THEN** the store keeps the snapshot entry and drops the covered
  incrementals

### Requirement: Removal SHALL work per document and per zone

`removeDocument` SHALL delete only that document's known records and clear
its drain set, spool, and registry state, and SHALL throw while a provider
for it is attached. `removeZone` SHALL delete the zone with every document
in it and clear all zone-scoped state.

#### Scenario: Remove one document

- **WHEN** documents `a` and `b` share the store and the caller removes
  `a`
- **THEN** `a`'s records are deleted, and `b`'s records and provider are
  untouched

#### Scenario: Remove the zone

- **WHEN** the caller removes the zone
- **THEN** every document's records go, and a later store start syncs
  nothing for them
