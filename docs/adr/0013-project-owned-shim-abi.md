# Project-owned Shim ABI

The Swift binding will expose a project-owned C shim ABI to Swift rather than importing upstream `yffi` directly. The shim can initially forward to upstream `yffi`, but it gives the project a stable native boundary for Swift ownership rules, error normalization, generated headers, XCFramework packaging, and feature gaps that require a local fork or direct `yrs` calls.
