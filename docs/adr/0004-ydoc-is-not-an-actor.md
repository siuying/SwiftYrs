# YDoc Is Not an Actor

The core Swift API will expose `YDoc` as a normal synchronous `final class`, not as an actor. Yrs already mediates document access through read/write transactions, and actor isolation would force `await` into nearly every operation while complicating observer callbacks and parity with JavaScript/Rust usage. The Swift wrapper will use closure-scoped transactions and carefully documented handle lifetimes instead.
