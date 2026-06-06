# Shim Is a Rust Crate Exporting C Symbols

The project-owned shim ABI will be implemented as a Rust crate that exports C symbols, rather than as a C layer wrapping upstream `yffi`. A Rust shim can forward to `yffi` where sufficient and call `yrs` directly for missing features such as awareness or sync protocol helpers, while owning the memory, error, and header contract consumed by Swift.
