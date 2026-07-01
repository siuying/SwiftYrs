import Foundation
import YrsBridgeFFI

public final class YWeakLink: YSharedType {
    init(handle: OpaquePointer) {
        super.init(handle: handle, observe: yrs_bridge_weak_observe)
    }
}

public enum YAssociation: Int32, Equatable, Sendable {
    case before = -1
    case after = 0
}

public struct YRelativePosition: Equatable, Sendable {
    public let data: Data
    public let json: Data

    init(data: Data, json: Data) {
        self.data = data
        self.json = json
    }

    public init(data bytes: Data) throws {
        let json = try withUInt8Pointer(bytes) { pointer, length in
            return try readingBuffer { yrs_bridge_relative_position_json_from_v1(pointer, length, &$0) }
        }
        self.init(data: bytes, json: json)
    }

    public init(json: Data) throws {
        let data = try withUInt8Pointer(json) { pointer, length in
            return try readingBuffer { yrs_bridge_relative_position_v1_from_json(pointer, length, &$0) }
        }
        self.init(data: data, json: json)
    }
}

extension YReadTransaction {
    public func weakLink(forKey key: String, in map: YMap) throws -> YWeakLink {
        try key.withCString { keyPointer in
            try makeBranch(YWeakLink.init) { yrs_bridge_map_get_weak_link(map.handle, handle, keyPointer, &$0) }
        }
    }

    public func dereference(_ weakLink: YWeakLink) throws -> YValue {
        var output = YrsBridgeValue()
        try throwIfNeeded(yrs_bridge_weak_deref(weakLink.handle, handle, &output))
        defer {
            yrs_bridge_value_destroy(output)
        }
        return YValueCodec.value(from: output)
    }

    public func values(from weakLink: YWeakLink) throws -> [YValue] {
        let data = try readingBuffer { yrs_bridge_weak_values_json(weakLink.handle, handle, &$0) }
        let object = try JSONSerialization.jsonObject(with: data)
        let values = object as? [Any] ?? []
        return values.map(YValueCodec.value(fromJSON:))
    }

    public func string(from weakLink: YWeakLink) throws -> String {
        let data = try readingBuffer { yrs_bridge_weak_string(weakLink.handle, handle, &$0) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func offset(of position: YRelativePosition, in _: YText) throws -> UInt32 {
        try withUInt8Pointer(position.json) { pointer, length in
            return try readingScalar(UInt32(0)) {
                yrs_bridge_relative_position_offset(pointer, length, handle, &$0)
            }
        }
    }

    /// The node and offset a relative position currently points at, resolved
    /// against this transaction's document state.
    public func resolve(_ position: YRelativePosition) throws -> YResolvedPosition {
        try withUInt8Pointer(position.json) { pointer, length in
            var value = YrsBridgeValue()
            var index: UInt32 = 0
            try throwIfNeeded(yrs_bridge_relative_position_resolve(pointer, length, handle, &value, &index))
            defer {
                yrs_bridge_value_destroy(value)
            }
            return YResolvedPosition(node: YValueCodec.value(from: value), offset: index)
        }
    }
}

/// Where a relative position lands in the current document state: the shared
/// node it anchors into and the offset within that node.
public struct YResolvedPosition: Equatable {
    public let node: YValue
    public let offset: UInt32
}

extension YWriteTransaction {
    public func setWeakLink(
        toKey sourceKey: String,
        in sourceMap: YMap,
        forKey targetKey: String,
        in targetMap: YMap
    ) throws -> YWeakLink {
        try sourceKey.withCString { sourcePointer in
            try targetKey.withCString { targetPointer in
                try makeBranch(YWeakLink.init) {
                    yrs_bridge_map_set_weak_link(
                        sourceMap.handle,
                        handle,
                        sourcePointer,
                        targetMap.handle,
                        targetPointer,
                        &$0
                    )
                }
            }
        }
    }

    public func setTextQuote(
        _ text: YText,
        start: UInt32,
        end: UInt32,
        startInclusive: Bool = true,
        endInclusive: Bool,
        forKey key: String,
        in map: YMap
    ) throws -> YWeakLink {
        try key.withCString { keyPointer in
            try makeBranch(YWeakLink.init) {
                yrs_bridge_text_set_quote(
                    text.handle,
                    handle,
                    start,
                    end,
                    startInclusive,
                    endInclusive,
                    map.handle,
                    keyPointer,
                    &$0
                )
            }
        }
    }

    public func setArrayQuote(
        _ array: YArray,
        start: UInt32,
        end: UInt32,
        startInclusive: Bool = true,
        endInclusive: Bool,
        forKey key: String,
        in map: YMap
    ) throws -> YWeakLink {
        try key.withCString { keyPointer in
            try makeBranch(YWeakLink.init) {
                yrs_bridge_array_set_quote(
                    array.handle,
                    handle,
                    start,
                    end,
                    startInclusive,
                    endInclusive,
                    map.handle,
                    keyPointer,
                    &$0
                )
            }
        }
    }

    public func relativePosition(in text: YText, at index: UInt32, association: YAssociation) throws -> YRelativePosition {
        try relativePosition(inTextBranch: text.handle, at: index, association: association)
    }

    /// A relative position inside a `YXmlText` — the text node y-prosemirror
    /// documents anchor cursors into.
    public func relativePosition(in text: YXmlText, at index: UInt32, association: YAssociation) throws -> YRelativePosition {
        try relativePosition(inTextBranch: text.handle, at: index, association: association)
    }

    /// A relative position anchored to an element itself rather than to a
    /// character offset — how y-prosemirror anchors a caret in an element with
    /// no text children (e.g. an empty paragraph).
    public func relativePosition(anchoredTo element: YXmlElement, association: YAssociation) throws -> YRelativePosition {
        let json = try readingBuffer {
            yrs_bridge_type_relative_position_json(element.handle, handle, association.rawValue, &$0)
        }
        let data = try readingBuffer {
            yrs_bridge_type_relative_position_v1(element.handle, handle, association.rawValue, &$0)
        }
        return YRelativePosition(data: data, json: json)
    }

    private func relativePosition(inTextBranch branch: OpaquePointer, at index: UInt32, association: YAssociation) throws -> YRelativePosition {
        let json = try readingBuffer {
            yrs_bridge_text_relative_position_json(branch, handle, index, association.rawValue, &$0)
        }
        let data = try readingBuffer {
            yrs_bridge_text_relative_position_v1(branch, handle, index, association.rawValue, &$0)
        }
        return YRelativePosition(data: data, json: json)
    }
}
