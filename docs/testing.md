# Testing under scheduling load

Run the full suite with `xcrun swift test`. To reproduce macOS scheduling delays,
run `node scripts/test-ci-load.mjs --workers 32 --runs 1`. CPU workers share a
monotonic epoch with three seconds busy and one second idle; the suite runs under
`taskpolicy -c background`. The default worker count is twice the available CPUs.
Each run writes a log and reports its raw exit code.

`node scripts/test-ci-load.mjs --cooperative --workers 0 --runs 1` copies a fixture
into `Tests/SwiftYrsHocuspocusTests/` for the run and removes it afterwards. Its 64
cases block cooperative workers for three seconds, with independent release
threads. The fixture stays disabled unless `SWIFTYRS_COOPERATIVE_LOAD=1`. This
mode must compile the fixture, so it cannot use `--skip-build`.

`SwiftYrsTestSupport` is a test-only target. It shares the 30-second watchdog,
completion streams, dedicated-thread helpers and acknowledged awareness ticks.
The watchdog cancels its losing task, so event waits must respond to cancellation.
One driver calls each checks object's `park()` and `tick()`; all mutable state is
locked because provider callbacks run on other executors. Cancelled maintenance
waits remain parked until a test delivers a stale tick and awaits its rejection.
Ticks and startup handshakes each have a 30-second watchdog.

Awareness lifetime tests drive the shared checks through constructor startup,
disconnect, reconnect, and terminal teardown. They assert remote tombstone clocks
and local removal counts after acknowledged ticks or events. A rejected stale
tick precedes provider deallocation assertions; advancing the injected clock
alone does not wake the maintenance task.

Contention tests park a dedicated writer thread and release it on an actual
transaction conflict. Async tests await entry and completion events. Core sync
tests advance an injected retry clock and still assert the production one-second
deadline; the five-millisecond backoff and provider maintenance cadence are
unchanged. Eventual startup, network delivery, compaction and saves allow at most
30 seconds. Polling checks buffered results before checking its deadline.

Negative assertions await the event being suppressed. Hocuspocus counts
synchronous forwarding attempts and awaits an inbound receive-loop marker.
WebRTC's discard test applies acknowledged wire updates to a separate witness
document, then checks that the receiving document stayed unchanged. After
CloudKit destruction, native unsubscribe may prevent the callback entirely, so
there is no callback event to await; the test drives the same scheduling entry
directly, checks that no debounce task exists, and attempts an explicit flush.

Hocuspocus destroy tests suspend the final awareness write through the
`onSocketSend` test hook and check that the socket is not closed while the write
is suspended. With `HOCUSPOCUS_TRACE=1`, the test server prints received awareness
frames and the close event in wire order, so the end-to-end test can compare
their sequence numbers.

`withE2EProcesses` owns subprocess shutdown and awaits it on dedicated queues.
Do not add fire-and-forget shutdown defers inside it. Pipe readability handlers
stop monitoring at EOF or after their owner disappears.

The observation lifetime regression keeps its watchdog and counters local to
`YObservationTests.swift` so the observation fix can be committed independently
of test support. It parks native delivery on a dedicated thread, unsubscribes
without waiting for delivery, and proves the queued callback is skipped. The
ASan job includes this regression alongside the subdocument lifecycle tests.
