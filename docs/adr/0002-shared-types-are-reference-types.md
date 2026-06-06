# Shared Types Are Reference Types

Swift shared CRDT types such as text, array, map, XML nodes, and weak links will be exposed as reference types rather than value-looking structs. They represent live branches with identity, observer subscriptions, and transaction-scoped mutation; copying the Swift object must not suggest copying CRDT content. Encoded updates, state vectors, snapshots, relative positions, deltas, and options remain value types.
