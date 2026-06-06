# Opaque Handles and Shim-owned Buffers

The shim ABI will use opaque native handles with explicit destroy functions and shim-owned byte/string buffers with matching release functions. Swift wrapper classes own and release only handles documented as owned; borrowed handles are valid only under their documented owner, transaction, or callback lifetime. Rust-returned memory is never freed with libc `free` or Swift deallocation.
