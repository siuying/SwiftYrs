import YrsBridgeFFI
import Foundation

public enum YError: Error, Equatable {
    case nullPointer
    case transactionConflict
    case readOnlyTransaction
    case decodeFailure
    case nativePanic
    case typeMismatch
    case unknown(code: Int32)
}

public struct YStateVector: Equatable, Sendable {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
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
    let handle: OpaquePointer

    public static func == (lhs: YDoc, rhs: YDoc) -> Bool {
        lhs === rhs
    }

    public init() {
        guard let handle = yrs_bridge_doc_new() else {
            preconditionFailure("YrsBridge failed to create a document")
        }
        self.handle = handle
    }

    public init(clientID: UInt64) {
        guard let handle = yrs_bridge_doc_new_with_client_id(clientID) else {
            preconditionFailure("YrsBridge failed to create a document")
        }
        self.handle = handle
    }

    public var clientID: UInt64 {
        yrs_bridge_doc_client_id(handle)
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
