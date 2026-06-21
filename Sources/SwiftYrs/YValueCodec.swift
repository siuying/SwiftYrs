import Foundation
import YrsBridgeFFI

/// The single seam for converting `YValue` across the FFI Surface.
///
/// A `YValue` crosses the boundary two ways, and both are owned here:
///
/// - the **`YrsBridgeValue` struct** representation, which carries live branch
///   handles (used by direct get/set/insert calls), and
/// - the **JSON-tag** representation, which carries embed/delta scalars (used by
///   text deltas, chunk decoding, and weak-link value lists).
///
/// `BridgeValueTag` — the discriminant mirroring the Rust shim — is a private
/// detail of this module, so the shim's value encoding lives in exactly one
/// place instead of being re-derived per call site.
enum YValueCodec {
    // MARK: Struct representation (carries live branch handles)

    /// Builds a `YValue` from the struct representation returned by the shim.
    static func value(from bridge: YrsBridgeValue) -> YValue {
        switch BridgeValueTag(rawValue: bridge.tag) {
        case .null:
            return .null
        case .bool:
            return .bool(bridge.bool_value)
        case .int:
            return .int(bridge.int_value)
        case .double:
            return .double(bridge.double_value)
        case .string:
            guard let bytes = bridge.bytes else {
                return .undefined
            }
            let data = Data(bytes: bytes, count: Int(bridge.len))
            return .string(String(data: data, encoding: .utf8) ?? "")
        case .binary:
            guard let bytes = bridge.bytes else {
                return .undefined
            }
            return .binary(Data(bytes: bytes, count: Int(bridge.len)))
        case .text:
            guard let branch = bridge.branch else {
                return .undefined
            }
            return .text(YText(handle: branch))
        case .map:
            guard let branch = bridge.branch else {
                return .undefined
            }
            return .map(YMap(handle: branch))
        case .array:
            guard let branch = bridge.branch else {
                return .undefined
            }
            return .array(YArray(handle: branch))
        case .xmlFragment:
            guard let branch = bridge.branch else {
                return .undefined
            }
            return .xmlFragment(YXmlFragment(handle: branch))
        case .weakLink:
            return .weakLink
        case .xmlElement:
            guard let branch = bridge.branch else {
                return .undefined
            }
            return .xmlElement(YXmlElement(handle: branch))
        case .xmlText:
            guard let branch = bridge.branch else {
                return .undefined
            }
            return .xmlText(YXmlText(handle: branch))
        case .undefined, .document, .none:
            return .undefined
        }
    }

    /// Lowers a `YValue` to the struct representation and passes it to `body`.
    /// The struct borrows `value`'s storage (string/binary bytes, branch
    /// handles) only for the duration of `body`.
    static func withBridgeValue<T>(_ value: YValue, _ body: (YrsBridgeValue) throws -> T) throws -> T {
        switch value {
        case .undefined:
            return try body(YrsBridgeValue(tag: .undefined))
        case .null:
            return try body(YrsBridgeValue(tag: .null))
        case let .bool(value):
            return try body(YrsBridgeValue(tag: .bool, bool_value: value))
        case let .int(value):
            return try body(YrsBridgeValue(tag: .int, int_value: value))
        case let .double(value):
            return try body(YrsBridgeValue(tag: .double, double_value: value))
        case let .string(value):
            let bytes = Array(value.utf8)
            return try bytes.withUnsafeBufferPointer { buffer in
                return try body(YrsBridgeValue(
                    tag: .string,
                    bytes: UnsafeMutablePointer(mutating: buffer.baseAddress),
                    len: UInt(buffer.count)
                ))
            }
        case let .binary(value):
            return try value.withUnsafeBytes { bytes in
                let pointer = bytes.bindMemory(to: UInt8.self).baseAddress
                return try body(YrsBridgeValue(tag: .binary, bytes: UnsafeMutablePointer(mutating: pointer), len: UInt(bytes.count)))
            }
        case let .text(value):
            return try body(YrsBridgeValue(tag: .text, branch: value.handle))
        case let .map(value):
            return try body(YrsBridgeValue(tag: .map, branch: value.handle))
        case let .array(value):
            return try body(YrsBridgeValue(tag: .array, branch: value.handle))
        case .document:
            throw YError.typeMismatch
        case let .xmlFragment(value):
            return try body(YrsBridgeValue(tag: .xmlFragment, branch: value.handle))
        case let .xmlElement(value):
            return try body(YrsBridgeValue(tag: .xmlElement, branch: value.handle))
        case let .xmlText(value):
            return try body(YrsBridgeValue(tag: .xmlText, branch: value.handle))
        case .weakLink:
            return try body(YrsBridgeValue(tag: .weakLink))
        }
    }

    // MARK: JSON-tag representation (carries embed/delta scalars)

    /// Builds a `YValue` from a decoded JSON-tag object (`{"tag": ..., ...}`).
    /// Branch/doc/xml tags decode to `.undefined`: the JSON representation only
    /// carries scalar content, never live handles.
    static func value(fromJSON object: Any?) -> YValue {
        guard let object = object as? [String: Any], let tag = object["tag"] as? String else {
            return value(fromRawJSON: object)
        }
        switch tag {
        case "null":
            return .null
        case "bool":
            return .bool((object["value"] as? Bool) ?? false)
        case "int":
            if let value = object["value"] as? Int64 {
                return .int(value)
            }
            return .int(Int64((object["value"] as? NSNumber)?.int64Value ?? 0))
        case "double":
            return .double((object["value"] as? NSNumber)?.doubleValue ?? 0)
        case "string":
            return .string((object["value"] as? String) ?? "")
        case "binary":
            let bytes = (object["value"] as? [NSNumber] ?? []).map { UInt8(truncating: $0) }
            return .binary(Data(bytes))
        case "array":
            let values = object["value"] as? [[String: Any]] ?? []
            let bytes = values.compactMap { value -> UInt8? in
                let native = Self.value(fromJSON: value)
                let byte: Int64
                switch native {
                case let .int(value):
                    byte = value
                case let .double(value) where value.rounded() == value:
                    byte = Int64(value)
                default:
                    return nil
                }
                guard byte >= 0, byte <= 255 else {
                    return nil
                }
                return UInt8(byte)
            }
            return bytes.count == values.count ? .binary(Data(bytes)) : .undefined
        case "text", "map-ref", "array-ref":
            return .undefined
        case "doc":
            return .undefined
        case "xml", "xml-fragment", "xml-element", "xml-text":
            return .undefined
        case "weak":
            return .weakLink
        default:
            return .undefined
        }
    }

    static func attributes(fromJSON object: Any?) -> YAttributes {
        guard let object = object as? [String: Any] else {
            return [:]
        }
        return object.mapValues { value(fromJSON: $0) }
    }

    static func jsonString(from attributes: YAttributes, rawScalars: Bool) throws -> String {
        let object = try attributes.mapValues { value in
            try jsonObject(from: value, rawScalars: rawScalars)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Decodes either the shared-type delta JSON shape (`retain`/`delete`/
    /// `insert`) or the event JSON shape (`kind`, `length`, `values`).
    static func delta(fromJSON object: Any?) -> [YTextDeltaOperation] {
        guard let entries = object as? [[String: Any]] else {
            return []
        }
        var operations: [YTextDeltaOperation] = []
        for entry in entries {
            if let kind = entry["kind"] as? String {
                appendEventDelta(entry, kind: kind, to: &operations)
            } else {
                appendSharedTypeDelta(entry, to: &operations)
            }
        }
        return operations
    }

    static func jsonString(from delta: [YTextDeltaOperation]) throws -> String {
        let objects = try delta.map { operation -> [String: Any] in
            switch operation {
            case let .retain(length, attributes):
                return [
                    "retain": Int(length),
                    "attributes": try attributesObject(from: attributes, rawScalars: true)
                ]
            case let .delete(length):
                return ["delete": Int(length)]
            case let .insert(value, attributes):
                return [
                    "insert": try jsonObject(from: value, rawScalars: false),
                    "attributes": try attributesObject(from: attributes, rawScalars: true)
                ]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    static func textChunks(from data: Data) throws -> [YTextChunk] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let chunks = object as? [[String: Any]] else {
            return []
        }
        return chunks.map { chunk in
            YTextChunk(
                insert: value(fromJSON: chunk["insert"]),
                attributes: attributes(fromJSON: chunk["attributes"])
            )
        }
    }

    /// Lowers a `YValue` to a JSON-shaped object.
    ///
    /// `rawScalars` selects the encoding: `true` produces bare scalars (for
    /// attribute maps and delta `retain`/`insert` attributes), `false` produces
    /// the tagged `{"tag": ..., "value": ...}` form. Either way, only scalar
    /// content is representable — shared types and documents throw
    /// `YError.typeMismatch`.
    static func jsonObject(from value: YValue, rawScalars: Bool) throws -> Any {
        if rawScalars {
            switch value {
            case .undefined, .null:
                return NSNull()
            case let .bool(value):
                return value
            case let .int(value):
                return NSNumber(value: value)
            case let .double(value):
                return NSNumber(value: value)
            case let .string(value):
                return value
            case let .binary(value):
                return Array(value)
            case .text, .map, .array, .document, .xmlFragment, .xmlElement, .xmlText, .weakLink:
                throw YError.typeMismatch
            }
        }

        switch value {
        case .undefined:
            return ["tag": "undefined"]
        case .null:
            return ["tag": "null"]
        case let .bool(value):
            return ["tag": "bool", "value": value]
        case let .int(value):
            return ["tag": "int", "value": NSNumber(value: value)]
        case let .double(value):
            return ["tag": "double", "value": NSNumber(value: value)]
        case let .string(value):
            return ["tag": "string", "value": value]
        case let .binary(value):
            return ["tag": "binary", "value": Array(value)]
        case .text, .map, .array, .document, .xmlFragment, .xmlElement, .xmlText, .weakLink:
            throw YError.typeMismatch
        }
    }

    private static func value(fromRawJSON object: Any?) -> YValue {
        switch object {
        case is NSNull:
            return .null
        case let value as Bool:
            return .bool(value)
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            let double = value.doubleValue
            if double.rounded() == double,
               double >= Double(Int64.min),
               double <= Double(Int64.max) {
                return .int(value.int64Value)
            }
            return .double(double)
        case let values as [Any]:
            let bytes = values.compactMap { value -> UInt8? in
                if let byte = value as? UInt8 {
                    return byte
                }
                guard let number = value as? NSNumber else {
                    return nil
                }
                let int = number.int64Value
                guard int >= 0, int <= 255, Double(int) == number.doubleValue else {
                    return nil
                }
                return UInt8(int)
            }
            return bytes.count == values.count ? .binary(Data(bytes)) : .undefined
        default:
            return .undefined
        }
    }

    private static func attributesObject(from attributes: YAttributes, rawScalars: Bool) throws -> [String: Any] {
        try attributes.mapValues { value in
            try jsonObject(from: value, rawScalars: rawScalars)
        }
    }

    private static func appendEventDelta(
        _ entry: [String: Any],
        kind: String,
        to operations: inout [YTextDeltaOperation]
    ) {
        switch kind {
        case "insert":
            let attributes = attributes(fromJSON: entry["attributes"])
            if let values = entry["values"] as? [Any] {
                for value in values {
                    operations.append(.insert(YValueCodec.value(fromJSON: value), attributes: attributes))
                }
            } else {
                operations.append(.insert(YValueCodec.value(fromJSON: entry["insert"]), attributes: attributes))
            }
        case "delete":
            operations.append(.delete(uint32(entry["length"])))
        case "retain":
            operations.append(.retain(uint32(entry["length"]), attributes: attributes(fromJSON: entry["attributes"])))
        default:
            break
        }
    }

    private static func appendSharedTypeDelta(
        _ entry: [String: Any],
        to operations: inout [YTextDeltaOperation]
    ) {
        let attributes = attributes(fromJSON: entry["attributes"])
        if let length = entry["retain"] {
            operations.append(.retain(uint32(length), attributes: attributes))
        } else if let length = entry["delete"] {
            operations.append(.delete(uint32(length)))
        } else if let insert = entry["insert"] {
            operations.append(.insert(value(fromJSON: insert), attributes: attributes))
        }
    }

    private static func uint32(_ value: Any?) -> UInt32 {
        (value as? UInt32) ?? (value as? NSNumber)?.uint32Value ?? 0
    }
}

/// The `tag` discriminant of `YrsBridgeValue`, mirroring the Rust shim's value
/// encoding. Must stay in sync with `yrs-bridge`.
private enum BridgeValueTag: Int32 {
    case undefined = 0
    case null = 1
    case bool = 2
    case int = 3
    case double = 4
    case string = 5
    case binary = 6
    case text = 7
    case map = 8
    case array = 9
    case document = 10
    case xmlFragment = 11
    case weakLink = 12
    case xmlElement = 13
    case xmlText = 14
}

private extension YrsBridgeValue {
    init(
        tag: BridgeValueTag,
        bool_value: Bool = false,
        int_value: Int64 = 0,
        double_value: Double = 0,
        bytes: UnsafeMutablePointer<UInt8>? = nil,
        len: UInt = 0,
        branch: OpaquePointer? = nil
    ) {
        self.init()
        self.tag = tag.rawValue
        self.bool_value = bool_value
        self.int_value = int_value
        self.double_value = double_value
        self.bytes = bytes
        self.len = len
        self.branch = branch
    }
}
