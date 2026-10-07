import Foundation
import SQLite
import SwiftYrs
@testable import SwiftYrsSQLite
import SwiftYrsTestSupport
import Testing

@Test
func successfulWritesAreOnDiskWhenTheWriteReturns() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "sync", doc: doc, store: store)
    try provider.start()
    defer { provider.destroy() }

    try insert("a", into: doc, named: "body")

    #expect(try updateRowCount(store, documentName: "sync") == 1)
    #expect(provider.pendingUpdateCount == 0)
    #expect(try await nextWriteResults(provider, count: 1) == ["persisted 1"])
    try await provider.flush()
}

@Test
func failedWritesAreReportedKeptInOrderAndRetriedByFlush() async throws {
    let databaseURL = try temporaryDatabaseURL()
    let store = try SQLiteStore(Connection(databaseURL.path))
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "retry", doc: doc, store: store)
    try provider.start()
    defer { provider.destroy() }

    try failUpdateInserts(store)
    try insert("a", into: doc, named: "body")
    try insert("b", into: doc, named: "body")

    #expect(provider.pendingUpdateCount == 2)
    #expect(try updateRowCount(store, documentName: "retry") == 0)
    // The second write retries the first one ahead of itself.
    #expect(try await nextWriteResults(provider, count: 3) == ["failed 1", "failed 1", "failed 2"])
    _ = try await nextTestEvent(provider.errors)

    let error = try await flushError(provider)
    #expect(error?.unsavedUpdates.map(\.sequence) == [1, 2])
    #expect(try await nextWriteResults(provider, count: 2) == ["failed 1", "failed 2"])
    #expect(provider.pendingUpdateCount == 2)

    try allowUpdateInserts(store)
    try await provider.flush()

    #expect(provider.pendingUpdateCount == 0)
    #expect(try await nextWriteResults(provider, count: 2) == ["persisted 1", "persisted 2"])
    provider.destroy()
    #expect(try reloadedString(at: databaseURL, documentName: "retry") == "ab")
}

@Test
func theNextWriteRetriesFailedUpdatesFirst() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "next", doc: doc, store: store)
    try provider.start()
    defer { provider.destroy() }

    try failUpdateInserts(store)
    try insert("a", into: doc, named: "body")
    #expect(provider.pendingUpdateCount == 1)

    try allowUpdateInserts(store)
    try insert("b", into: doc, named: "body")

    #expect(provider.pendingUpdateCount == 0)
    #expect(try updateRowCount(store, documentName: "next") == 2)
    #expect(try await nextWriteResults(provider, count: 3) == ["failed 1", "persisted 1", "persisted 2"])
}

@Test
func flushWaitsForAWriteInProgress() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "in-flight", doc: doc, store: store)
    let gate = Gate()
    provider.testHooks.willWriteUpdates = { gate.pass() }
    try provider.start()
    defer { provider.destroy() }

    DispatchQueue.global().async {
        try? insert("a", into: doc, named: "body")
    }
    try await nextTestEvent(gate.entered)
    #expect(provider.pendingUpdateCount == 1)

    let flushed = Flag()
    let flush = Task { () -> String? in
        defer { flushed.set() }
        return await errorDescription { try await provider.flush() }
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!flushed.isSet)

    gate.open()
    #expect(try await testTaskValue(flush) == nil)
    #expect(provider.pendingUpdateCount == 0)
    #expect(try updateRowCount(store, documentName: "in-flight") == 1)
}

@Test
func compactAndWaitReturnsOnceTheSnapshotIsOnDisk() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let options = try SQLiteProviderOptions(autoCompact: false)
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "await", doc: doc, store: store, options: options)
    try provider.start()
    defer { provider.destroy() }

    try insert("a", into: doc, named: "body")
    try insert("b", into: doc, named: "body")
    try insert("c", into: doc, named: "body")
    try await provider.compactAndWait()

    #expect(try updateKinds(store, documentName: "await") == ["snapshot"])
}

@Test
func flushWaitsForAutoCompaction() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let options = try SQLiteProviderOptions(autoCompact: true, compactThreshold: 2)
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "auto", doc: doc, store: store, options: options)
    try provider.start()
    defer { provider.destroy() }

    try insert("a", into: doc, named: "body")
    try insert("b", into: doc, named: "body")
    try await provider.flush()

    #expect(try updateKinds(store, documentName: "auto") == ["snapshot"])
}

@Test
func closeWaitsForAnAutoCompactionInProgress() async throws {
    let databaseURL = try temporaryDatabaseURL()
    let store = try SQLiteStore(Connection(databaseURL.path))
    let options = try SQLiteProviderOptions(autoCompact: true, compactThreshold: 2)
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "close", doc: doc, store: store, options: options)
    let gate = Gate()
    provider.testHooks.willCommitCompaction = { gate.pass() }
    try provider.start()

    try insert("a", into: doc, named: "body")
    try insert("b", into: doc, named: "body")
    try await nextTestEvent(gate.entered)

    let closed = Flag()
    let close = Task { () -> String? in
        defer { closed.set() }
        return await errorDescription { try await provider.close() }
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!closed.isSet)
    #expect(try updateRowCount(store, documentName: "close") == 2)

    gate.open()
    #expect(try await testTaskValue(close) == nil)

    #expect(try updateKinds(store, documentName: "close") == ["snapshot"])
    #expect(throws: SQLiteProviderError.destroyed) {
        try provider.start()
    }
    // close() unregistered the document, so the same store can open it again.
    let reloadedDoc = YDoc()
    let reloaded = SQLiteProvider(documentName: "close", doc: reloadedDoc, store: store)
    try reloaded.start()
    defer { reloaded.destroy() }
    #expect(try string(in: reloadedDoc, named: "body") == "ab")
}

@Test
func closeReportsUnsavedUpdatesAndStillTearsDown() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "unsaved", doc: doc, store: store)
    try provider.start()

    try failUpdateInserts(store)
    try insert("a", into: doc, named: "body")

    var unsaved: [SQLitePendingUpdate] = []
    do {
        try await provider.close()
        Issue.record("Expected close to report the unsaved update")
    } catch let error as SQLiteFlushError {
        unsaved = error.unsavedUpdates
    }
    #expect(unsaved.map(\.sequence) == [1])
    // Edits after close are not observed.
    try insert("b", into: doc, named: "body")
    #expect(provider.pendingUpdateCount == 1)

    try allowUpdateInserts(store)
    let reloadedDoc = YDoc()
    let reloaded = SQLiteProvider(documentName: "unsaved", doc: reloadedDoc, store: store)
    try reloaded.start()
    defer { reloaded.destroy() }
    #expect(try string(in: reloadedDoc, named: "body") == "")

    // The error carries the update bytes, so the caller can still save them.
    for pending in unsaved {
        try reloadedDoc.apply(pending.update)
    }
    #expect(try string(in: reloadedDoc, named: "body") == "a")
    #expect(try updateRowCount(store, documentName: "unsaved") == 1)
}

@Test
func staleCompactionDoesNotOverwriteANewerCompaction() throws {
    let databaseURL = try temporaryDatabaseURL()
    try seedSingleSnapshotRow("a", at: databaseURL, documentName: "stale")
    let options = try SQLiteProviderOptions(autoCompact: false)

    // Session A loads the single row.
    let staleDoc = YDoc()
    let stale = SQLiteProvider(
        documentName: "stale",
        doc: staleDoc,
        store: try SQLiteStore(Connection(databaseURL.path)),
        options: options
    )
    try stale.start()
    defer { stale.destroy() }

    // Session B appends and compacts.
    let newerDoc = YDoc()
    let newer = SQLiteProvider(
        documentName: "stale",
        doc: newerDoc,
        store: try SQLiteStore(Connection(databaseURL.path)),
        options: options
    )
    try newer.start()
    try insert("b", into: newerDoc, named: "body")
    try newer.compact()
    newer.destroy()

    try stale.compact()

    #expect(try reloadedString(at: databaseURL, documentName: "stale") == "ab")
}

@Test
func compactionKeepsRowsAnotherSessionAppended() throws {
    let databaseURL = try temporaryDatabaseURL()
    try seedSingleSnapshotRow("a", at: databaseURL, documentName: "shared")
    let options = try SQLiteProviderOptions(autoCompact: false)

    let firstDoc = YDoc()
    let first = SQLiteProvider(
        documentName: "shared",
        doc: firstDoc,
        store: try SQLiteStore(Connection(databaseURL.path)),
        options: options
    )
    try first.start()
    defer { first.destroy() }

    let secondDoc = YDoc()
    let second = SQLiteProvider(
        documentName: "shared",
        doc: secondDoc,
        store: try SQLiteStore(Connection(databaseURL.path)),
        options: options
    )
    try second.start()
    try insert("b", into: secondDoc, named: "body")
    second.destroy()

    try first.compact()

    #expect(try reloadedString(at: databaseURL, documentName: "shared") == "ab")
}

@Test
func closeWaitsForASynchronousCompactionAndRejectsLaterOnes() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let options = try SQLiteProviderOptions(autoCompact: false)
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "manual", doc: doc, store: store, options: options)
    let gate = Gate()
    provider.testHooks.willCommitCompaction = { gate.pass() }
    try provider.start()
    try insert("a", into: doc, named: "body")

    DispatchQueue.global().async {
        try? provider.compact()
    }
    try await nextTestEvent(gate.entered)

    let closed = Flag()
    let close = Task { () -> String? in
        defer { closed.set() }
        return await errorDescription { try await provider.close() }
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!closed.isSet)

    gate.open()
    #expect(try await testTaskValue(close) == nil)
    #expect(try updateKinds(store, documentName: "manual") == ["snapshot"])

    // A compaction after close must not resurrect a removed document.
    #expect(throws: SQLiteProviderError.destroyed) {
        try provider.compact()
    }
    try store.removeDocument(named: "manual")
    #expect(try updateRowCount(store, documentName: "manual") == 0)
}

@Test
func concurrentClosesShareOneTeardown() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let provider = SQLiteProvider(documentName: "shared-close", doc: YDoc(), store: store)
    let gate = Gate()
    provider.testHooks.willReleaseDocument = { gate.pass() }
    try provider.start()

    let first = Task { await errorDescription { try await provider.close() } }
    try await nextTestEvent(gate.entered)
    let secondClosed = Flag()
    let second = Task { () -> String? in
        defer { secondClosed.set() }
        return await errorDescription { try await provider.close() }
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!secondClosed.isSet)

    gate.open()
    #expect(try await testTaskValue(second) == nil)
    // When either call returns, the document name is already released.
    let reloaded = SQLiteProvider(documentName: "shared-close", doc: YDoc(), store: store)
    try reloaded.start()
    defer { reloaded.destroy() }
    #expect(try await testTaskValue(first) == nil)
}

@Test
func aFailureAfterInsertingDoesNotDuplicateRows() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "count", doc: doc, store: store)
    let failOnce = FailOnce()
    provider.testHooks.willCountUpdates = { try failOnce.check() }
    try provider.start()
    defer { provider.destroy() }

    try insert("a", into: doc, named: "body")
    #expect(provider.pendingUpdateCount == 1)
    #expect(try updateRowCount(store, documentName: "count") == 0)

    try await provider.flush()

    #expect(provider.pendingUpdateCount == 0)
    #expect(try updateRowCount(store, documentName: "count") == 1)
    #expect(try await nextWriteResults(provider, count: 2) == ["failed 1", "persisted 1"])
}

// MARK: - Helpers

private struct InjectedFailure: Error {}

private final class FailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    func check() throws {
        let shouldFail = lock.withLock {
            defer { failed = true }
            return !failed
        }
        if shouldFail {
            throw InjectedFailure()
        }
    }
}

private func nextWriteResults(_ provider: SQLiteProvider, count: Int) async throws -> [String] {
    var results: [String] = []
    for _ in 0..<count {
        switch try await nextTestEvent(provider.writeResults) {
        case let .persisted(sequence):
            results.append("persisted \(sequence)")
        case let .failed(sequence, _):
            results.append("failed \(sequence)")
        }
    }
    return results
}

private func flushError(_ provider: SQLiteProvider) async throws -> SQLiteFlushError? {
    do {
        try await provider.flush()
        Issue.record("Expected flush to fail")
        return nil
    } catch let error as SQLiteFlushError {
        return error
    }
}

/// Makes every update insert fail inside SQLite, as a full disk or a
/// read-only database would.
private func failUpdateInserts(_ store: SQLiteStore) throws {
    try store.sync { connection in
        try connection.execute(
            """
            CREATE TRIGGER swiftyrs_test_fail_inserts BEFORE INSERT ON swiftyrs_sqlite_updates
            BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;
            """
        )
    }
}

private func allowUpdateInserts(_ store: SQLiteStore) throws {
    try store.sync { connection in
        try connection.execute("DROP TRIGGER swiftyrs_test_fail_inserts")
    }
}

private func seedSingleSnapshotRow(_ value: String, at databaseURL: URL, documentName: String) throws {
    let doc = YDoc()
    let provider = SQLiteProvider(
        documentName: documentName,
        doc: doc,
        store: try SQLiteStore(Connection(databaseURL.path))
    )
    try provider.start()
    try insert(value, into: doc, named: "body")
    try provider.compact()
    provider.destroy()
}

private func reloadedString(at databaseURL: URL, documentName: String) throws -> String {
    let doc = YDoc()
    let provider = SQLiteProvider(
        documentName: documentName,
        doc: doc,
        store: try SQLiteStore(Connection(databaseURL.path))
    )
    try provider.start()
    defer { provider.destroy() }
    return try string(in: doc, named: "body")
}

/// Parks a provider's background work until the test opens it.
private final class Gate: @unchecked Sendable {
    let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isOpen = false

    init() {
        (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func pass() {
        let shouldWait = lock.withLock { !isOpen }
        guard shouldWait else { return }
        enteredContinuation.yield()
        semaphore.wait()
    }

    func open() {
        lock.withLock { isOpen = true }
        semaphore.signal()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}

private func errorDescription(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch {
        return String(describing: error)
    }
}
