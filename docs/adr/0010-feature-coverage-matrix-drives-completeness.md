# Feature Coverage Matrix Drives Completeness

The Swift binding will define completeness through a Feature Coverage Matrix before implementation work begins. Each targeted feature from the y-crdt README parity table must map to `yrs` support, current `yffi` support, Swift API shape, any FFI gap, and required tests. A feature is not considered complete until its Swift API is backed by tests.
