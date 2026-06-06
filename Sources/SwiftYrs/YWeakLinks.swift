import Foundation
import YrsBridgeFFI

public struct YWeakLink: Equatable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func == (lhs: YWeakLink, rhs: YWeakLink) -> Bool {
        lhs.handle == rhs.handle
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
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try bytes.withUnsafeBytes { rawBytes in
            guard let pointer = rawBytes.bindMemory(to: UInt8.self).baseAddress else {
                throw YError.nullPointer
            }
            try throwIfNeeded(yrs_bridge_relative_position_json_from_v1(pointer, UInt(rawBytes.count), &buffer))
        }
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        self.init(data: bytes, json: SwiftYrs.data(from: buffer))
    }

    public init(json: Data) throws {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try json.withUnsafeBytes { bytes in
            guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else {
                throw YError.nullPointer
            }
            try throwIfNeeded(yrs_bridge_relative_position_v1_from_json(pointer, UInt(bytes.count), &buffer))
        }
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        self.init(data: SwiftYrs.data(from: buffer), json: json)
    }
}

extension YReadTransaction {
    public func weakLink(forKey key: String, in map: YMap) throws -> YWeakLink {
        try key.withCString { keyPointer in
            var output: OpaquePointer?
            try throwIfNeeded(yrs_bridge_map_get_weak_link(map.handle, handle, keyPointer, &output))
            guard let output else {
                throw YError.nullPointer
            }
            return YWeakLink(handle: output)
        }
    }

    public func dereference(_ weakLink: YWeakLink) throws -> YValue {
        var output = YrsBridgeValue()
        try throwIfNeeded(yrs_bridge_weak_deref(weakLink.handle, handle, &output))
        defer {
            yrs_bridge_value_destroy(output)
        }
        return nativeValue(output)
    }

    public func values(from weakLink: YWeakLink) throws -> [YValue] {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_weak_values_json(weakLink.handle, handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        let object = try JSONSerialization.jsonObject(with: SwiftYrs.data(from: buffer))
        let values = object as? [Any] ?? []
        return values.map(nativeValue(fromJSONObject:))
    }

    public func string(from weakLink: YWeakLink) throws -> String {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_weak_string(weakLink.handle, handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return String(data: SwiftYrs.data(from: buffer), encoding: .utf8) ?? ""
    }

    public func offset(of position: YRelativePosition, in _: YText) throws -> UInt32 {
        try position.json.withUnsafeBytes { bytes in
            guard let pointer = bytes.bindMemory(to: UInt8.self).baseAddress else {
                throw YError.nullPointer
            }
            var output: UInt32 = 0
            try throwIfNeeded(yrs_bridge_relative_position_offset(pointer, UInt(bytes.count), handle, &output))
            return output
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
                var output: OpaquePointer?
                try throwIfNeeded(yrs_bridge_map_set_weak_link(
                    sourceMap.handle,
                    handle,
                    sourcePointer,
                    targetMap.handle,
                    targetPointer,
                    &output
                ))
                guard let output else {
                    throw YError.nullPointer
                }
                return YWeakLink(handle: output)
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
            var output: OpaquePointer?
            try throwIfNeeded(yrs_bridge_text_set_quote(
                text.handle,
                handle,
                start,
                end,
                startInclusive,
                endInclusive,
                map.handle,
                keyPointer,
                &output
            ))
            guard let output else {
                throw YError.nullPointer
            }
            return YWeakLink(handle: output)
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
            var output: OpaquePointer?
            try throwIfNeeded(yrs_bridge_array_set_quote(
                array.handle,
                handle,
                start,
                end,
                startInclusive,
                endInclusive,
                map.handle,
                keyPointer,
                &output
            ))
            guard let output else {
                throw YError.nullPointer
            }
            return YWeakLink(handle: output)
        }
    }

    public func relativePosition(in text: YText, at index: UInt32, association: YAssociation) throws -> YRelativePosition {
        var jsonBuffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_text_relative_position_json(text.handle, handle, index, association.rawValue, &jsonBuffer))
        defer {
            yrs_bridge_buffer_destroy(jsonBuffer)
        }

        var dataBuffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_text_relative_position_v1(text.handle, handle, index, association.rawValue, &dataBuffer))
        defer {
            yrs_bridge_buffer_destroy(dataBuffer)
        }

        return YRelativePosition(data: SwiftYrs.data(from: dataBuffer), json: SwiftYrs.data(from: jsonBuffer))
    }

    public func weakLink(forKey key: String, in map: YMap) throws -> YWeakLink {
        try YReadTransaction(handle: handle).weakLink(forKey: key, in: map)
    }

    public func dereference(_ weakLink: YWeakLink) throws -> YValue {
        try YReadTransaction(handle: handle).dereference(weakLink)
    }

    public func values(from weakLink: YWeakLink) throws -> [YValue] {
        try YReadTransaction(handle: handle).values(from: weakLink)
    }

    public func string(from weakLink: YWeakLink) throws -> String {
        try YReadTransaction(handle: handle).string(from: weakLink)
    }

    public func offset(of position: YRelativePosition, in text: YText) throws -> UInt32 {
        try YReadTransaction(handle: handle).offset(of: position, in: text)
    }
}

extension YWeakLink {
    public func observe(_ callback: @escaping (YObservationEvent) -> Void) throws -> Observation {
        try makeObservation(callback) { context, callback in
            yrs_bridge_weak_observe(handle, context, callback)
        }
    }

    public func events() throws -> AsyncStream<YObservationEvent> {
        try makeEventStream(observe: observe)
    }
}
