# Preserve Y-prefixed Types with Swift Methods

The Swift API will preserve recognizable Yjs/Yrs type names such as `YDoc`, `YText`, `YMap`, `YArray`, `YAwareness`, and `YUndoManager`, while using Swift-native method names and argument labels. This keeps cross-language parity obvious without exposing callers to C-style FFI names or Rust method spelling.
