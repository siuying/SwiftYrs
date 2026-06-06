# Defer YArray Move After Upstream Removal

The initial Swift binding will not expose a YArray move API. The y-crdt README still lists YArray move as supported, but the current `external/y-crdt` checkout removed `Array::move_to`, `move_range_to`, and the `yffi` `yarray_move` export in commit `2d52291` after earlier move implementations existed. Move semantics can be revisited only if upstream restores the feature or this project deliberately implements and tests it as new Rust work.
