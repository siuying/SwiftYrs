# Encoded Protocol Data Uses Typed Payloads

Encoded updates, state vectors, snapshots, awareness updates, relative positions, and sync protocol messages will be distinct Swift value types wrapping bytes rather than interchangeable `Data`. This keeps networking simple through explicit byte access while preventing callers from passing one protocol payload kind where another is expected.
