import Foundation
import SQLite
import SwiftYrs
@testable import SwiftYrsSQLite
import SwiftYrsTestSupport
import Testing

@Test
func flushThroughWaitsForALaterObservation() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "later", doc: doc, store: store)
    try provider.start()
    defer { provider.destroy() }
    #expect(provider.observedSequence == 0)

    try insert("a", into: doc, named: "body")
    #expect(provider.observedSequence == 1)

    let flushed = Flag()
    let flush = Task { () -> String? in
        defer { flushed.set() }
        return await errorDescription { try await provider.flush(through: 2) }
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(!flushed.isSet)

    try insert("b", into: doc, named: "body")
    #expect(try await testTaskValue(flush) == nil)
    #expect(provider.observedSequence == 2)
    #expect(provider.pendingUpdateCount == 0)
    #expect(try updateRowCount(store, documentName: "later") == 2)
}

@Test
func flushThroughReturnsAtOnceForAnObservedSequence() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "observed", doc: doc, store: store)
    try provider.start()
    defer { provider.destroy() }

    try await provider.flush(through: 0)
    try insert("a", into: doc, named: "body")
    try await provider.flush(through: 1)

    #expect(try updateRowCount(store, documentName: "observed") == 1)
}

@Test
func destroyFailsWaitersForUnobservedSequences() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let provider = SQLiteProvider(documentName: "destroy-wait", doc: YDoc(), store: store)
    try provider.start()

    let waiter = Task { await errorDescription { try await provider.flush(through: 1) } }
    try await Task.sleep(for: .milliseconds(50))
    provider.destroy()

    #expect(try await testTaskValue(waiter) == String(describing: SQLiteProviderError.destroyed))
    // Nothing is observed after teardown, so a later wait fails at once.
    await #expect(throws: SQLiteProviderError.destroyed) {
        try await provider.flush(through: 1)
    }
}

@Test
func closeFailsWaitersForUnobservedSequences() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let provider = SQLiteProvider(documentName: "close-wait", doc: YDoc(), store: store)
    try provider.start()

    let waiter = Task { await errorDescription { try await provider.flush(through: 1) } }
    try await Task.sleep(for: .milliseconds(50))
    try await provider.close()

    #expect(try await testTaskValue(waiter) == String(describing: SQLiteProviderError.destroyed))
}

@Test
func flushThroughReportsAWriteFailure() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "fail-through", doc: doc, store: store)
    try provider.start()
    defer { provider.destroy() }

    try failUpdateInserts(store)
    let waiter = Task { () -> [UInt64]? in
        do {
            try await provider.flush(through: 1)
            return nil
        } catch let error as SQLiteFlushError {
            return error.unsavedUpdates.map(\.sequence)
        } catch {
            return nil
        }
    }
    try await Task.sleep(for: .milliseconds(50))
    try insert("a", into: doc, named: "body")

    #expect(try await testTaskValue(waiter) == [1])
    #expect(provider.pendingUpdateCount == 1)
}

@Test
func manyConcurrentWaitersAllResume() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let doc = YDoc()
    let provider = SQLiteProvider(documentName: "many", doc: doc, store: store)
    try provider.start()
    defer { provider.destroy() }

    let updateCount: UInt64 = 10
    let waiters = (0..<100).map { index in
        Task { await errorDescription { try await provider.flush(through: UInt64(index) % updateCount + 1) } }
    }
    try await Task.sleep(for: .milliseconds(50))
    for index in 0..<updateCount {
        try insert("\(index)", into: doc, named: "body")
    }

    for waiter in waiters {
        #expect(try await testTaskValue(waiter) == nil)
    }
    #expect(try updateRowCount(store, documentName: "many") == Int(updateCount))
}

@Test
func cancellingAWaiterThrowsCancellationError() async throws {
    let store = try SQLiteStore(Connection(temporaryDatabaseURL().path))
    let provider = SQLiteProvider(documentName: "cancel", doc: YDoc(), store: store)
    try provider.start()
    defer { provider.destroy() }

    let waiter = Task { () -> Bool in
        do {
            try await provider.flush(through: 1)
            return false
        } catch {
            return error is CancellationError
        }
    }
    try await Task.sleep(for: .milliseconds(50))
    waiter.cancel()

    #expect(try await testTaskValue(waiter))
}
