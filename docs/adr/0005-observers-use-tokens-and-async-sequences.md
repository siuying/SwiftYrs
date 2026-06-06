# Observers Use Tokens and Async Sequences

The Swift API will expose observer callbacks through cancellable `Observation` tokens, with `AsyncSequence` event streams layered on top for structured concurrency. The token maps directly to `yffi` subscriptions and `yunobserve`, making native lifetime ownership explicit, while async streams provide an idiomatic Swift consumption style without making the whole document API actor-based or async-first.
