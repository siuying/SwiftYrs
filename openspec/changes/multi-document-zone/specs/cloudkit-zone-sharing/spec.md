## ADDED Requirements

### Requirement: A store SHALL support one shared zone for many documents

The codec SHALL accept a zone mode at construction: one zone per document
(legacy, the default), or one shared zone with a caller-supplied name. In
shared-zone mode, every document of the store SHALL live in that zone. The
legacy mode SHALL keep its current zone names and record names unchanged.

#### Scenario: Two documents in one zone

- **WHEN** a store uses shared-zone mode and providers for documents `a`
  and `b` both send changes
- **THEN** every record of both documents lives in the one shared zone

#### Scenario: Legacy mode is unchanged

- **WHEN** a store uses the default mode
- **THEN** each document's records live in that document's own zone, with
  the same zone and record names as before this change

### Requirement: A record name SHALL identify its document

In shared-zone mode, every record name SHALL begin with an encoded
document component, and the codec SHALL recover the document name from a
record name alone. The `documentName` record field SHALL stay, and decode
SHALL fail with a typed error when the name and the field disagree. A
record name that does not parse SHALL produce a typed error, never a
route to another document.

#### Scenario: Route a deleted record

- **WHEN** the engine reports a deleted record ID from the shared zone
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

In shared-zone mode, `removeDocument` SHALL delete only that document's
known records and clear its drain set, spool, and registry state, and
SHALL throw while a provider for it is attached. A `removeZone` operation
SHALL delete the shared zone with every document in it and clear all
zone-scoped state. Legacy mode SHALL keep its current behaviour:
`removeDocument` deletes the document's zone.

#### Scenario: Remove one document from a shared zone

- **WHEN** documents `a` and `b` share a zone and the caller removes `a`
- **THEN** `a`'s records are deleted, and `b`'s records and provider are
  untouched

#### Scenario: Remove the zone

- **WHEN** the caller removes the zone
- **THEN** every document's records go, and a later store start syncs
  nothing for them
