import Foundation

public struct TestWatchdogTimeout: Error {}

// Operations must respond to cancellation so the watchdog can finish its task group.
public func withTestTimeout<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(30))
            throw TestWatchdogTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func nextValue<Value: Sendable>(_ stream: AsyncStream<Value>) async throws -> Value {
    var iterator = stream.makeAsyncIterator()
    guard let value = await iterator.next() else { throw CancellationError() }
    return value
}

public func nextTestEvent<Value: Sendable>(_ stream: AsyncStream<Value>) async throws -> Value {
    try await withTestTimeout { try await nextValue(stream) }
}

// Awaits a task through a stream, so the watchdog can interrupt the wait.
// The forwarding task ends when `task` does; tests release held work on failure.
public func testTaskValue<Value: Sendable>(_ task: Task<Value, Never>) async throws -> Value {
    let result = AsyncStream.makeStream(of: Value.self)
    Task {
        result.continuation.yield(await task.value)
        result.continuation.finish()
    }
    return try await nextTestEvent(result.stream)
}

public func testCompletion(_ stream: AsyncStream<Void>) async -> Bool {
    do { _ = try await nextTestEvent(stream); return true }
    catch { return false }
}

// One test driver calls park/tick; provider callbacks may arrive on other executors.
// Cancelled waits stay parked so the driver can acknowledge a rejected stale tick.
public final class AwarenessChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var primed = false
    private let sleeping = AsyncStream.makeStream(of: Void.self)
    private let checks = AsyncStream.makeStream(of: Bool.self)

    public init() {}

    public func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock { continuations.append(continuation) }
            sleeping.continuation.yield(())
        }
    }

    public func checked(_ active: Bool) { checks.continuation.yield(active) }

    private func parkWithoutWatchdog() async throws {
        guard !lock.withLock({ primed }) else { return }
        _ = try await nextValue(sleeping.stream)
        lock.withLock { primed = true }
    }

    public func park() async throws {
        try await withTestTimeout { try await self.parkWithoutWatchdog() }
    }

    public func tick() async throws -> Bool {
        try await withTestTimeout {
            try await self.parkWithoutWatchdog()
            let continuation = self.lock.withLock {
                self.primed = false
                return self.continuations.removeFirst()
            }
            continuation.resume()
            let active = try await nextValue(self.checks.stream)
            if active { try await self.parkWithoutWatchdog() }
            return active
        }
    }
}

public func onTestThread<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    let result = AsyncStream.makeStream(of: Result<Value, Error>.self)
    Thread {
        result.continuation.yield(Result(catching: operation))
        result.continuation.finish()
    }.start()
    return try await nextTestEvent(result.stream).get()
}

// Only the dedicated writer thread blocks; its test driver awaits an entry event.
public final class TestThreadGate: @unchecked Sendable {
    private let entered = AsyncStream.makeStream(of: Void.self)
    private let release = DispatchSemaphore(value: 0)

    public init() {}
    public func enterAndWait() { entered.continuation.yield(()); release.wait() }
    public func open() { release.signal() }
    public func waitForEntry() async throws { _ = try await nextTestEvent(entered.stream) }
}
