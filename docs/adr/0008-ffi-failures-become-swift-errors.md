# FFI Failures Become Swift Errors

The Swift API will convert `yffi` null sentinels, booleans, and integer error codes into throwing APIs where an operation fails. Optionals are reserved for legitimate absence, such as a missing map key or optional child lookup. This keeps native ABI details out of the public API and gives callers normal Swift `try`/`catch` semantics.
