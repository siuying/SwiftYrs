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
        let json = try bytes.withUnsafeBytes { rawBytes -> Data in
            guard let pointer = rawBytes.bindMemory(to: UInt8.self).baseAddress else {
                throw YError.nullPointer
            }
            return try readingBuffer { yrs_bridge_relative_position_json_from_v1(pointer, UInt(rawBytes.count), &$0) }
        }
        self.init(data: bytes, json: json)
    }

    public init(json: Data) throws {
        let data = try json.withUnsafeBytes { bytes -> Data in
            guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else {
                throw YError.nullPointer
            }
            return try readingBuffer { yrs_bridge_relative_position_v1_from_json(pointer, UInt(bytes.count), &$0) }
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
        try position.json.withUnsafeBytes { bytes -> UInt32 in
            guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else {
                throw YError.nullPointer
            }
            return try readingScalar(UInt32(0)) {
                yrs_bridge_relative_position_offset(pointer, UInt(bytes.count), handle, &$0)
            }
        }
    }
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
        let json = try readingBuffer {
            yrs_bridge_text_relative_position_json(text.handle, handle, index, association.rawValue, &$0)
        }
        let data = try readingBuffer {
            yrs_bridge_text_relative_position_v1(text.handle, handle, index, association.rawValue, &$0)
        }
        return YRelativePosition(data: data, json: json)
    }
}
