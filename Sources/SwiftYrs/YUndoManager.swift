import Foundation
import YrsBridgeFFI

public final class YUndoManager {
    private let document: YDoc
    private let handle: OpaquePointer

    public init(document: YDoc) {
        guard let handle = yrs_bridge_undo_manager_new() else {
            preconditionFailure("Yrs bridge failed to create an undo manager")
        }
        self.document = document
        self.handle = handle
    }

    deinit {
        yrs_bridge_undo_manager_destroy(handle)
    }

    public var undoStackCount: Int {
        get {
            var output: UInt = 0
            _ = yrs_bridge_undo_manager_undo_stack_len(handle, &output)
            return Int(output)
        }
    }

    public var redoStackCount: Int {
        get {
            var output: UInt = 0
            _ = yrs_bridge_undo_manager_redo_stack_len(handle, &output)
            return Int(output)
        }
    }

    public func addScope(_ text: YText) throws {
        try addScope(text.handle)
    }

    public func addScope(_ map: YMap) throws {
        try addScope(map.handle)
    }

    public func addScope(_ array: YArray) throws {
        try addScope(array.handle)
    }

    public func addScope(_ xml: YXmlFragment) throws {
        try addScope(xml.handle)
    }

    public func addScope(_ xml: YXmlElement) throws {
        try addScope(xml.handle)
    }

    public func includeOrigin(_ origin: String) {
        origin.withCString { pointer in
            _ = yrs_bridge_undo_manager_include_origin(handle, pointer)
        }
    }

    public func excludeOrigin(_ origin: String) {
        origin.withCString { pointer in
            _ = yrs_bridge_undo_manager_exclude_origin(handle, pointer)
        }
    }

    public func undo() throws -> Bool {
        var output = false
        try throwIfNeeded(yrs_bridge_undo_manager_undo(handle, &output))
        return output
    }

    public func redo() throws -> Bool {
        var output = false
        try throwIfNeeded(yrs_bridge_undo_manager_redo(handle, &output))
        return output
    }

    public func stopCapturing() {
        yrs_bridge_undo_manager_stop(handle)
    }

    public func clear() {
        yrs_bridge_undo_manager_clear(handle)
    }

    public func observeItemAdded(_ callback: @escaping (YObservationEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_undo_manager_observe_item_added(handle, context, callback)
        }
    }

    public func observeItemPopped(_ callback: @escaping (YObservationEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_undo_manager_observe_item_popped(handle, context, callback)
        }
    }

    private func addScope(_ branch: OpaquePointer) throws {
        try throwIfNeeded(yrs_bridge_undo_manager_add_scope(handle, document.handle, branch))
    }
}
