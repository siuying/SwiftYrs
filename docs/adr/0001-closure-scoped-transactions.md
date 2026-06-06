# Closure-scoped Transactions

The Swift API will expose document reads and writes primarily through closure-scoped transaction methods instead of requiring users to manually create, commit, and destroy transaction handles. This keeps the public API idiomatic for Swift 6 and lets the wrapper guarantee FFI transaction cleanup when a closure returns or throws, while still allowing internal explicit handles around the `yffi` transaction pointers.
