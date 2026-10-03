import YrsBridgeFFI
import Foundation

public enum YError: Error, Equatable {
    case nullPointer
    case transactionConflict
    case readOnlyTransaction
    case decodeFailure
    case nativePanic
    case typeMismatch
    case invalidGUID
    case duplicateSubdocGUID
    /// State-from-snapshot encoding is available only when document garbage
    /// collection is disabled.
    case garbageCollectionEnabled
    case unknown(code: Int32)
}

public struct YStateVector: Equatable, Sendable {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }
}

/// A Yjs-compatible snapshot. Use `decode(_:)` to validate external bytes; use
/// `YReadTransaction.snapshot()` to capture a document snapshot.
public struct YSnapshot: Equatable, Sendable {
    /// The canonical V1 snapshot bytes.
    public let data: Data

    /// Wraps snapshot bytes without validation.
    public init(_ data: Data) {
        self.data = data
    }

    /// Returns the canonical V1 snapshot bytes.
    public func encode() -> Data {
        data
    }

    /// Decodes and validates V1 snapshot bytes.
    public static func decode(_ data: Data) throws -> YSnapshot {
        let encoded = try withUInt8Pointer(data) { pointer, length in
            try readingBuffer {
                yrs_bridge_snapshot_decode(pointer, length, &$0)
            }
        }
        return YSnapshot(encoded)
    }
}

public struct YUpdate: Equatable, Sendable {
    public enum Encoding: Equatable, Sendable {
        case v1
        case v2
    }

    public let data: Data
    public let encoding: Encoding

    public init(_ data: Data, encoding: Encoding) {
        self.data = data
        self.encoding = encoding
    }

    public static func v1(_ data: Data) -> YUpdate {
        YUpdate(data, encoding: .v1)
    }

    public static func v2(_ data: Data) -> YUpdate {
        YUpdate(data, encoding: .v2)
    }
}

func throwIfNeeded(_ code: Int32) throws {
    switch code {
    case 0:
        return
    case 1:
        throw YError.nullPointer
    case 2:
        throw YError.transactionConflict
    case 3:
        throw YError.readOnlyTransaction
    case 4:
        throw YError.decodeFailure
    case 5:
        throw YError.nativePanic
    case 6:
        throw YError.typeMismatch
    case 7:
        throw YError.invalidGUID
    case 8:
        throw YError.duplicateSubdocGUID
    case 9:
        throw YError.garbageCollectionEnabled
    default:
        throw YError.unknown(code: code)
    }
}

func data(from buffer: YrsBridgeBuffer) -> Data {
    guard let pointer = buffer.data, buffer.len > 0 else {
        return Data()
    }
    return Data(bytes: pointer, count: Int(buffer.len))
}

/// A document is a reference to a native handle, not data safe to mutate from
/// several threads at once. It is `@unchecked Sendable` so transports can hold
/// it across actors and callbacks, on the contract that all access is confined
/// to a single actor or serial queue (see `CLAUDE.md` on foreign-threaded
/// handles). The conformance lives here, in core, so every transport relies on
/// the same contract rather than re-declaring it.
extension YDoc: @unchecked Sendable {}

public final class YDoc: Equatable {
    /// Options that control how a document stores deleted content.
    public struct Options: Equatable, Sendable {
        /// Keeps deleted structs so state can be encoded from an earlier
        /// snapshot. This must be `true` for state-from-snapshot encoding.
        public var skipGC: Bool

        /// Creates document options. Garbage collection is enabled by default.
        public init(skipGC: Bool = false) {
            self.skipGC = skipGC
        }
    }

    let handle: OpaquePointer
    /// The options used when this document was created.
    public let options: Options

    public static func == (lhs: YDoc, rhs: YDoc) -> Bool {
        lhs === rhs
    }

    public init() {
        self.options = Options()
        guard let handle = yrs_bridge_doc_new() else {
            preconditionFailure("YrsBridge failed to create a document")
        }
        self.handle = handle
    }

    /// Creates a document with the supplied options.
    public init(options: Options) {
        self.options = options
        guard let handle = yrs_bridge_doc_new_with_options(options.skipGC) else {
            preconditionFailure("YrsBridge failed to create a document")
        }
        self.handle = handle
    }

    /// Creates a document with a fixed client ID and the supplied options.
    public init(clientID: UInt64, options: Options = Options()) {
        self.options = options
        guard let handle = yrs_bridge_doc_new_with_client_id_and_options(clientID, options.skipGC) else {
            preconditionFailure("YrsBridge failed to create a document")
        }
        self.handle = handle
    }

    /// Wraps an owned document handle produced by the bridge, such as the boxed
    /// clone returned for a subdocument (ADR-0024). Every handle owns one
    /// reference to the document's store and `deinit` drops that reference; the
    /// store lives while any reference remains, so a handle's lifetime is
    /// independent of the parent document's.
    init(handle: OpaquePointer) throws {
        do {
            let skipGC = try readingScalar(false) {
                yrs_bridge_doc_skip_gc(handle, &$0)
            }
            self.handle = handle
            self.options = Options(skipGC: skipGC)
        } catch {
            yrs_bridge_doc_destroy(handle)
            throw error
        }
    }

    public var clientID: UInt64 {
        yrs_bridge_doc_client_id(handle)
    }

    /// The document's GUID. A subdocument keeps its GUID across replicas, which
    /// makes it the natural key for a provider's `documentName`. Uniqueness is
    /// the application's contract, not something the CRDT enforces.
    public var guid: String {
        get throws {
            let data = try readingBuffer { yrs_bridge_doc_guid(handle, &$0) }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    deinit {
        yrs_bridge_doc_destroy(handle)
    }

    public func read<T>(_ body: (YReadTransaction) throws -> T) throws -> T {
        var transaction: OpaquePointer?
        try throwIfNeeded(yrs_bridge_doc_read_transaction(handle, &transaction))
        guard let transaction else {
            throw YError.nullPointer
        }
        defer {
            yrs_bridge_transaction_destroy(transaction)
        }
        return try body(YReadTransaction(handle: transaction))
    }

    public func write<T>(_ body: (YWriteTransaction) throws -> T) throws -> T {
        var transaction: OpaquePointer?
        try throwIfNeeded(yrs_bridge_doc_write_transaction(handle, &transaction))
        guard let transaction else {
            throw YError.nullPointer
        }
        defer {
            yrs_bridge_transaction_destroy(transaction)
        }
        return try body(YWriteTransaction(handle: transaction))
    }

    public func write<T>(origin: String, _ body: (YWriteTransaction) throws -> T) throws -> T {
        var transaction: OpaquePointer?
        try origin.withCString { pointer in
            try throwIfNeeded(yrs_bridge_doc_write_transaction_with_origin(handle, pointer, &transaction))
        }
        guard let transaction else {
            throw YError.nullPointer
        }
        defer {
            yrs_bridge_transaction_destroy(transaction)
        }
        return try body(YWriteTransaction(handle: transaction))
    }

    public func stateVector() throws -> YStateVector {
        try read { transaction in
            try transaction.stateVector()
        }
    }

    public func clientClock(clientID: UInt64) throws -> UInt32 {
        try read { transaction in
            try transaction.clientClock(clientID: clientID)
        }
    }

    public func encodeStateAsUpdateV1(from stateVector: YStateVector? = nil) throws -> YUpdate {
        try read { transaction in
            try transaction.encodeStateAsUpdateV1(from: stateVector)
        }
    }

    public func encodeStateAsUpdateV2(from stateVector: YStateVector? = nil) throws -> YUpdate {
        try read { transaction in
            try transaction.encodeStateAsUpdateV2(from: stateVector)
        }
    }

    /// Encodes the state from `snapshot` as a V1 update. The document must have
    /// been created with `Options(skipGC: true)`.
    public func encodeStateFromSnapshotV1(_ snapshot: YSnapshot) throws -> YUpdate {
        try read { transaction in
            try transaction.encodeStateFromSnapshotV1(snapshot)
        }
    }

    /// Encodes the state from `snapshot` as a V2 update. The document must have
    /// been created with `Options(skipGC: true)`.
    public func encodeStateFromSnapshotV2(_ snapshot: YSnapshot) throws -> YUpdate {
        try read { transaction in
            try transaction.encodeStateFromSnapshotV2(snapshot)
        }
    }

    /// Encodes the state from `snapshot` using the selected update encoding.
    /// The document must have been created with `Options(skipGC: true)`.
    public func encodeStateFromSnapshot(
        _ snapshot: YSnapshot,
        encoding: YUpdate.Encoding = .v1
    ) throws -> YUpdate {
        switch encoding {
        case .v1:
            try encodeStateFromSnapshotV1(snapshot)
        case .v2:
            try encodeStateFromSnapshotV2(snapshot)
        }
    }

    public func encodeClientStateAsUpdateV1(clientID: UInt64, fromClock: UInt32) throws -> YUpdate {
        try read { transaction in
            try transaction.encodeClientStateAsUpdateV1(clientID: clientID, fromClock: fromClock)
        }
    }

    public func encodeClientStateAsUpdateV2(clientID: UInt64, fromClock: UInt32) throws -> YUpdate {
        try read { transaction in
            try transaction.encodeClientStateAsUpdateV2(clientID: clientID, fromClock: fromClock)
        }
    }

    public func apply(_ update: YUpdate) throws {
        try write { transaction in
            try transaction.apply(update)
        }
    }

    public func text(named name: String) throws -> YText {
        try name.withCString { pointer in
            guard let handle = yrs_bridge_doc_get_text(handle, pointer) else {
                throw YError.nullPointer
            }
            return YText(handle: handle)
        }
    }

    public func map(named name: String) throws -> YMap {
        try name.withCString { pointer in
            guard let handle = yrs_bridge_doc_get_map(handle, pointer) else {
                throw YError.nullPointer
            }
            return YMap(handle: handle)
        }
    }

    public func array(named name: String) throws -> YArray {
        try name.withCString { pointer in
            guard let handle = yrs_bridge_doc_get_array(handle, pointer) else {
                throw YError.nullPointer
            }
            return YArray(handle: handle)
        }
    }

    public func xmlFragment(named name: String) throws -> YXmlFragment {
        try name.withCString { pointer in
            guard let handle = yrs_bridge_doc_get_xml_fragment(handle, pointer) else {
                throw YError.nullPointer
            }
            return YXmlFragment(handle: handle)
        }
    }
}

public class YReadTransaction {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public var isWritable: Bool {
        get throws {
            try readingScalar(false) { yrs_bridge_transaction_is_writable(handle, &$0) }
        }
    }

    public func stateVector() throws -> YStateVector {
        try YStateVector(readingBuffer { yrs_bridge_transaction_state_vector_v1(handle, &$0) })
    }

    /// Captures the document state at this transaction. The returned snapshot
    /// can be used to encode historical state when the document has garbage
    /// collection disabled.
    public func snapshot() throws -> YSnapshot {
        try YSnapshot(readingBuffer { yrs_bridge_transaction_snapshot(handle, &$0) })
    }

    public func clientClock(clientID: UInt64) throws -> UInt32 {
        try readingScalar(UInt32(0)) {
            yrs_bridge_transaction_client_clock(handle, clientID, &$0)
        }
    }

    public func encodeStateAsUpdateV1(from stateVector: YStateVector? = nil) throws -> YUpdate {
        let updateData = try withOptionalBytes(stateVector?.data) { pointer, count in
            try readingBuffer { yrs_bridge_transaction_state_diff_v1(handle, pointer, UInt(count), &$0) }
        }
        return .v1(updateData)
    }

    public func encodeStateAsUpdateV2(from stateVector: YStateVector? = nil) throws -> YUpdate {
        let updateData = try withOptionalBytes(stateVector?.data) { pointer, count in
            try readingBuffer { yrs_bridge_transaction_state_diff_v2(handle, pointer, UInt(count), &$0) }
        }
        return .v2(updateData)
    }

    /// Encodes the state from `snapshot` as a V1 update. The document must have
    /// been created with `Options(skipGC: true)`.
    public func encodeStateFromSnapshotV1(_ snapshot: YSnapshot) throws -> YUpdate {
        let updateData = try withUInt8Pointer(snapshot.data) { pointer, length in
            try readingBuffer {
                yrs_bridge_transaction_encode_state_from_snapshot_v1(
                    handle,
                    pointer,
                    length,
                    &$0
                )
            }
        }
        return .v1(updateData)
    }

    /// Encodes the state from `snapshot` as a V2 update. The document must have
    /// been created with `Options(skipGC: true)`.
    public func encodeStateFromSnapshotV2(_ snapshot: YSnapshot) throws -> YUpdate {
        let updateData = try withUInt8Pointer(snapshot.data) { pointer, length in
            try readingBuffer {
                yrs_bridge_transaction_encode_state_from_snapshot_v2(
                    handle,
                    pointer,
                    length,
                    &$0
                )
            }
        }
        return .v2(updateData)
    }

    public func encodeClientStateAsUpdateV1(clientID: UInt64, fromClock: UInt32) throws -> YUpdate {
        let updateData = try readingBuffer {
            yrs_bridge_transaction_client_state_diff_v1(handle, clientID, fromClock, &$0)
        }
        return .v1(updateData)
    }

    public func encodeClientStateAsUpdateV2(clientID: UInt64, fromClock: UInt32) throws -> YUpdate {
        let updateData = try readingBuffer {
            yrs_bridge_transaction_client_state_diff_v2(handle, clientID, fromClock, &$0)
        }
        return .v2(updateData)
    }
}

/// A write transaction is also a read transaction: every read accessor on
/// `YReadTransaction` is available here through inheritance.
public final class YWriteTransaction: YReadTransaction {
    public func apply(_ update: YUpdate) throws {
        try withUInt8Pointer(update.data) { pointer, length in
            switch update.encoding {
            case .v1:
                try throwIfNeeded(yrs_bridge_transaction_apply_v1(handle, pointer, length))
            case .v2:
                try throwIfNeeded(yrs_bridge_transaction_apply_v2(handle, pointer, length))
            }
        }
    }
}

private func withOptionalBytes<T>(
    _ data: Data?,
    _ body: (UnsafePointer<UInt8>?, Int) throws -> T
) throws -> T {
    guard let data else {
        return try body(nil, 0)
    }
    return try withUInt8Pointer(data) { pointer, length in
        try body(pointer, Int(length))
    }
}
