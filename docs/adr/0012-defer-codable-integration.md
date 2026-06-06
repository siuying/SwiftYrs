# Defer Codable Integration

Codable integration will be deferred until the explicit `YValue` model and core shared-type API are stable. Yjs content includes undefined, binary data, live shared types, weak links, subdocuments, and XML nodes, so Codable cannot represent the complete model without hiding important semantics. Later Codable helpers should target only the JSON-compatible subset.
