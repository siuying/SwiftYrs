import Foundation
import YrsBridgeFFI

public typealias YAttributes = [String: YValue]

public enum YValue: Equatable {
    case undefined
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case binary(Data)
    case text(YText)
    case map(YMap)
    case array(YArray)
    case document(YDoc)
    case xmlFragment(YXmlFragment)
    case xmlElement(YXmlElement)
    case xmlText(YXmlText)
    case weakLink

    public static func == (lhs: YValue, rhs: YValue) -> Bool {
        switch (lhs, rhs) {
        case (.undefined, .undefined), (.null, .null), (.weakLink, .weakLink):
            true
        case let (.bool(lhs), .bool(rhs)):
            lhs == rhs
        case let (.int(lhs), .int(rhs)):
            lhs == rhs
        case let (.double(lhs), .double(rhs)):
            lhs == rhs
        case let (.string(lhs), .string(rhs)):
            lhs == rhs
        case let (.binary(lhs), .binary(rhs)):
            lhs == rhs
        case let (.text(lhs), .text(rhs)):
            lhs == rhs
        case let (.map(lhs), .map(rhs)):
            lhs == rhs
        case let (.array(lhs), .array(rhs)):
            lhs == rhs
        case let (.document(lhs), .document(rhs)):
            lhs === rhs
        case let (.xmlFragment(lhs), .xmlFragment(rhs)):
            lhs == rhs
        case let (.xmlElement(lhs), .xmlElement(rhs)):
            lhs == rhs
        case let (.xmlText(lhs), .xmlText(rhs)):
            lhs == rhs
        default:
            false
        }
    }
}

public enum YTextDeltaOperation: Equatable {
    case retain(UInt32, attributes: YAttributes = [:])
    case delete(UInt32)
    case insert(YValue, attributes: YAttributes = [:])
}

public struct YTextChunk: Equatable {
    public let insert: YValue
    public let attributes: YAttributes

    public init(insert: YValue, attributes: YAttributes) {
        self.insert = insert
        self.attributes = attributes
    }
}

public enum YXmlNode: Equatable {
    case fragment(YXmlFragment)
    case element(YXmlElement)
    case text(YXmlText)
}

public struct YSubdoc: Equatable {
    public let guid: String
}

public struct YText: Equatable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func == (lhs: YText, rhs: YText) -> Bool {
        lhs.handle == rhs.handle
    }
}

public struct YMap: Equatable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func == (lhs: YMap, rhs: YMap) -> Bool {
        lhs.handle == rhs.handle
    }
}

public struct YArray: Equatable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func == (lhs: YArray, rhs: YArray) -> Bool {
        lhs.handle == rhs.handle
    }
}

public struct YXmlFragment: Equatable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func == (lhs: YXmlFragment, rhs: YXmlFragment) -> Bool {
        lhs.handle == rhs.handle
    }
}

public struct YXmlElement: Equatable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func == (lhs: YXmlElement, rhs: YXmlElement) -> Bool {
        lhs.handle == rhs.handle
    }
}

public struct YXmlText: Equatable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func == (lhs: YXmlText, rhs: YXmlText) -> Bool {
        lhs.handle == rhs.handle
    }
}

extension YReadTransaction {
    public func length(of text: YText) throws -> UInt32 {
        var result: UInt32 = 0
        try throwIfNeeded(yrs_bridge_text_len(text.handle, handle, &result))
        return result
    }

    public func string(from text: YText) throws -> String {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_text_string(text.handle, handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return String(data: data(from: buffer), encoding: .utf8) ?? ""
    }

    public func chunks(from text: YText) throws -> [YTextChunk] {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_text_chunks_json(text.handle, handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return try decodeTextChunks(from: data(from: buffer))
    }

    public func delta(from text: YText) throws -> [YTextDeltaOperation] {
        try chunks(from: text).map { chunk in
            .insert(chunk.insert, attributes: chunk.attributes)
        }
    }

    public func get(_ key: String, from map: YMap) throws -> YValue {
        try key.withCString { keyPointer in
            var output = YrsBridgeValue()
            try throwIfNeeded(yrs_bridge_map_get(map.handle, handle, keyPointer, &output))
            defer {
                yrs_bridge_value_destroy(output)
            }
            return nativeValue(output)
        }
    }

    public func entriesJSON(from map: YMap) throws -> [String: Any] {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_map_entries_json(map.handle, handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        let object = try JSONSerialization.jsonObject(with: data(from: buffer))
        return object as? [String: Any] ?? [:]
    }

    public func count(of array: YArray) throws -> UInt32 {
        var result: UInt32 = 0
        try throwIfNeeded(yrs_bridge_array_len(array.handle, handle, &result))
        return result
    }

    public func get(_ index: UInt32, from array: YArray) throws -> YValue {
        var output = YrsBridgeValue()
        try throwIfNeeded(yrs_bridge_array_get(array.handle, handle, index, &output))
        defer {
            yrs_bridge_value_destroy(output)
        }
        return nativeValue(output)
    }

    public func valuesJSON(from array: YArray) throws -> [Any] {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_array_values_json(array.handle, handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        let object = try JSONSerialization.jsonObject(with: data(from: buffer))
        return object as? [Any] ?? []
    }

    public func childCount(of xml: YXmlFragment) throws -> UInt32 {
        try xmlChildCount(xml.handle, transaction: handle)
    }

    public func childCount(of xml: YXmlElement) throws -> UInt32 {
        try xmlChildCount(xml.handle, transaction: handle)
    }

    public func string(from xml: YXmlFragment) throws -> String {
        try xmlString(xml.handle, transaction: handle)
    }

    public func string(from xml: YXmlElement) throws -> String {
        try xmlString(xml.handle, transaction: handle)
    }

    public func child(at index: UInt32, in xml: YXmlFragment) throws -> YXmlNode {
        try xmlChild(at: index, in: xml.handle, transaction: handle)
    }

    public func child(at index: UInt32, in xml: YXmlElement) throws -> YXmlNode {
        try xmlChild(at: index, in: xml.handle, transaction: handle)
    }

    public func tag(of element: YXmlElement) throws -> String {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_xml_element_tag(element.handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return String(data: data(from: buffer), encoding: .utf8) ?? ""
    }

    public func getAttribute(_ key: String, from xml: YXmlElement) throws -> YValue {
        try xmlAttribute(key, from: xml.handle, transaction: handle)
    }

    public func getAttribute(_ key: String, from xml: YXmlText) throws -> YValue {
        try xmlAttribute(key, from: xml.handle, transaction: handle)
    }

    public func length(of xmlText: YXmlText) throws -> UInt32 {
        var result: UInt32 = 0
        try throwIfNeeded(yrs_bridge_xml_text_len(xmlText.handle, handle, &result))
        return result
    }

    public func string(from xmlText: YXmlText) throws -> String {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_xml_text_string(xmlText.handle, handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        return String(data: data(from: buffer), encoding: .utf8) ?? ""
    }

    public func subdocGuids() throws -> [String] {
        var buffer = YrsBridgeBuffer(data: nil, len: 0)
        try throwIfNeeded(yrs_bridge_transaction_subdoc_guids(handle, &buffer))
        defer {
            yrs_bridge_buffer_destroy(buffer)
        }
        let object = try JSONSerialization.jsonObject(with: data(from: buffer))
        return object as? [String] ?? []
    }

    public func subdoc(forKey key: String, in map: YMap) throws -> YSubdoc {
        try key.withCString { keyPointer in
            var buffer = YrsBridgeBuffer(data: nil, len: 0)
            try throwIfNeeded(yrs_bridge_map_get_subdoc_guid(map.handle, handle, keyPointer, &buffer))
            defer {
                yrs_bridge_buffer_destroy(buffer)
            }
            return YSubdoc(guid: String(data: data(from: buffer), encoding: .utf8) ?? "")
        }
    }
}

extension YWriteTransaction {
    public func insert(_ value: String, into text: YText, at index: UInt32) throws {
        try value.withCString { pointer in
            try throwIfNeeded(yrs_bridge_text_insert(text.handle, handle, index, pointer))
        }
    }

    public func insert(_ value: String, into text: YText, at index: UInt32, attributes: YAttributes) throws {
        let attributes = try jsonString(from: attributes, rawScalars: true)
        try value.withCString { valuePointer in
            try attributes.withCString { attributesPointer in
                try throwIfNeeded(
                    yrs_bridge_text_insert_with_attributes_json(
                        text.handle,
                        handle,
                        index,
                        valuePointer,
                        attributesPointer
                    )
                )
            }
        }
    }

    public func format(_ text: YText, at index: UInt32, length: UInt32, attributes: YAttributes) throws {
        let attributes = try jsonString(from: attributes, rawScalars: true)
        try attributes.withCString { pointer in
            try throwIfNeeded(yrs_bridge_text_format_json(text.handle, handle, index, length, pointer))
        }
    }

    public func insertEmbed(_ value: YValue, into text: YText, at index: UInt32, attributes: YAttributes = [:]) throws {
        let attributes = try jsonString(from: attributes, rawScalars: true)
        try withNativeValue(value) { nativeValue in
            try attributes.withCString { attributesPointer in
                try throwIfNeeded(yrs_bridge_text_insert_embed(text.handle, handle, index, nativeValue, attributesPointer))
            }
        }
    }

    public func applyDelta(_ delta: [YTextDeltaOperation], to text: YText) throws {
        let delta = try jsonString(from: delta)
        try delta.withCString { pointer in
            try throwIfNeeded(yrs_bridge_text_apply_delta_json(text.handle, handle, pointer))
        }
    }

    public func remove(from text: YText, at index: UInt32, length: UInt32) throws {
        try throwIfNeeded(yrs_bridge_text_remove(text.handle, handle, index, length))
    }

    public func set(_ value: YValue, forKey key: String, in map: YMap) throws {
        try key.withCString { keyPointer in
            try withNativeValue(value) { nativeValue in
                try throwIfNeeded(yrs_bridge_map_set(map.handle, handle, keyPointer, nativeValue))
            }
        }
    }

    public func remove(_ key: String, from map: YMap) throws {
        try key.withCString { keyPointer in
            try throwIfNeeded(yrs_bridge_map_remove(map.handle, handle, keyPointer))
        }
    }

    public func insert(_ value: YValue, into array: YArray, at index: UInt32) throws {
        try withNativeValue(value) { nativeValue in
            try throwIfNeeded(yrs_bridge_array_insert(array.handle, handle, index, nativeValue))
        }
    }

    public func insertMap(into array: YArray, at index: UInt32) throws -> YMap {
        var output: OpaquePointer?
        try throwIfNeeded(yrs_bridge_array_insert_map(array.handle, handle, index, &output))
        guard let output else {
            throw YError.nullPointer
        }
        return YMap(handle: output)
    }

    public func insertArray(into array: YArray, at index: UInt32) throws -> YArray {
        var output: OpaquePointer?
        try throwIfNeeded(yrs_bridge_array_insert_array(array.handle, handle, index, &output))
        guard let output else {
            throw YError.nullPointer
        }
        return YArray(handle: output)
    }

    public func setMap(forKey key: String, in map: YMap) throws -> YMap {
        try key.withCString { keyPointer in
            var output: OpaquePointer?
            try throwIfNeeded(yrs_bridge_map_set_map(map.handle, handle, keyPointer, &output))
            guard let output else {
                throw YError.nullPointer
            }
            return YMap(handle: output)
        }
    }

    public func setArray(forKey key: String, in map: YMap) throws -> YArray {
        try key.withCString { keyPointer in
            var output: OpaquePointer?
            try throwIfNeeded(yrs_bridge_map_set_array(map.handle, handle, keyPointer, &output))
            guard let output else {
                throw YError.nullPointer
            }
            return YArray(handle: output)
        }
    }

    public func insertText(into array: YArray, at index: UInt32) throws -> YText {
        var output: OpaquePointer?
        try throwIfNeeded(yrs_bridge_array_insert_text(array.handle, handle, index, &output))
        guard let output else {
            throw YError.nullPointer
        }
        return YText(handle: output)
    }

    public func setText(forKey key: String, in map: YMap) throws -> YText {
        try key.withCString { keyPointer in
            var output: OpaquePointer?
            try throwIfNeeded(yrs_bridge_map_set_text(map.handle, handle, keyPointer, &output))
            guard let output else {
                throw YError.nullPointer
            }
            return YText(handle: output)
        }
    }

    public func remove(from array: YArray, at index: UInt32, length: UInt32) throws {
        try throwIfNeeded(yrs_bridge_array_remove(array.handle, handle, index, length))
    }

    public func insertElement(named name: String, into xml: YXmlFragment, at index: UInt32) throws -> YXmlElement {
        try insertXmlElement(named: name, into: xml.handle, at: index, transaction: handle)
    }

    public func insertElement(named name: String, into xml: YXmlElement, at index: UInt32) throws -> YXmlElement {
        try insertXmlElement(named: name, into: xml.handle, at: index, transaction: handle)
    }

    public func insertText(into xml: YXmlFragment, at index: UInt32) throws -> YXmlText {
        try insertXmlText(into: xml.handle, at: index, transaction: handle)
    }

    public func insertText(into xml: YXmlElement, at index: UInt32) throws -> YXmlText {
        try insertXmlText(into: xml.handle, at: index, transaction: handle)
    }

    public func remove(from xml: YXmlFragment, at index: UInt32, length: UInt32) throws {
        try throwIfNeeded(yrs_bridge_xml_remove(xml.handle, handle, index, length))
    }

    public func remove(from xml: YXmlElement, at index: UInt32, length: UInt32) throws {
        try throwIfNeeded(yrs_bridge_xml_remove(xml.handle, handle, index, length))
    }

    public func setAttribute(_ value: YValue, forKey key: String, in xml: YXmlElement) throws {
        try setXmlAttribute(value, forKey: key, in: xml.handle, transaction: handle)
    }

    public func setAttribute(_ value: YValue, forKey key: String, in xml: YXmlText) throws {
        try setXmlAttribute(value, forKey: key, in: xml.handle, transaction: handle)
    }

    public func removeAttribute(_ key: String, from xml: YXmlElement) throws {
        try removeXmlAttribute(key, from: xml.handle, transaction: handle)
    }

    public func removeAttribute(_ key: String, from xml: YXmlText) throws {
        try removeXmlAttribute(key, from: xml.handle, transaction: handle)
    }

    public func insert(_ value: String, into xmlText: YXmlText, at index: UInt32) throws {
        try value.withCString { pointer in
            try throwIfNeeded(yrs_bridge_xml_text_insert(xmlText.handle, handle, index, pointer))
        }
    }

    public func remove(from xmlText: YXmlText, at index: UInt32, length: UInt32) throws {
        try throwIfNeeded(yrs_bridge_xml_text_remove(xmlText.handle, handle, index, length))
    }

    public func setNewSubdoc(forKey key: String, in map: YMap) throws -> YSubdoc {
        try key.withCString { keyPointer in
            var buffer = YrsBridgeBuffer(data: nil, len: 0)
            try throwIfNeeded(yrs_bridge_map_set_new_subdoc(map.handle, handle, keyPointer, &buffer))
            defer {
                yrs_bridge_buffer_destroy(buffer)
            }
            return YSubdoc(guid: String(data: data(from: buffer), encoding: .utf8) ?? "")
        }
    }

    public func loadSubdoc(forKey key: String, in map: YMap) throws {
        try key.withCString { keyPointer in
            try throwIfNeeded(yrs_bridge_map_load_subdoc(map.handle, handle, keyPointer))
        }
    }

    public func clearSubdoc(forKey key: String, in map: YMap) throws {
        try key.withCString { keyPointer in
            try throwIfNeeded(yrs_bridge_map_clear_subdoc(map.handle, handle, keyPointer))
        }
    }
}

private func xmlChildCount(_ xml: OpaquePointer, transaction: OpaquePointer) throws -> UInt32 {
    var result: UInt32 = 0
    try throwIfNeeded(yrs_bridge_xml_len(xml, transaction, &result))
    return result
}

private func xmlString(_ xml: OpaquePointer, transaction: OpaquePointer) throws -> String {
    var buffer = YrsBridgeBuffer(data: nil, len: 0)
    try throwIfNeeded(yrs_bridge_xml_string(xml, transaction, &buffer))
    defer {
        yrs_bridge_buffer_destroy(buffer)
    }
    return String(data: data(from: buffer), encoding: .utf8) ?? ""
}

private func xmlChild(at index: UInt32, in xml: OpaquePointer, transaction: OpaquePointer) throws -> YXmlNode {
    var value = YrsBridgeValue()
    try throwIfNeeded(yrs_bridge_xml_get(xml, transaction, index, &value))
    defer {
        yrs_bridge_value_destroy(value)
    }
    switch nativeValue(value) {
    case let .xmlFragment(value):
        return .fragment(value)
    case let .xmlElement(value):
        return .element(value)
    case let .xmlText(value):
        return .text(value)
    default:
        throw YError.typeMismatch
    }
}

private func insertXmlElement(
    named name: String,
    into xml: OpaquePointer,
    at index: UInt32,
    transaction: OpaquePointer
) throws -> YXmlElement {
    try name.withCString { pointer in
        var output: OpaquePointer?
        try throwIfNeeded(yrs_bridge_xml_insert_element(xml, transaction, index, pointer, &output))
        guard let output else {
            throw YError.nullPointer
        }
        return YXmlElement(handle: output)
    }
}

private func insertXmlText(into xml: OpaquePointer, at index: UInt32, transaction: OpaquePointer) throws -> YXmlText {
    var output: OpaquePointer?
    try throwIfNeeded(yrs_bridge_xml_insert_text(xml, transaction, index, &output))
    guard let output else {
        throw YError.nullPointer
    }
    return YXmlText(handle: output)
}

private func xmlAttribute(_ key: String, from xml: OpaquePointer, transaction: OpaquePointer) throws -> YValue {
    try key.withCString { keyPointer in
        var output = YrsBridgeValue()
        try throwIfNeeded(yrs_bridge_xml_get_attribute(xml, transaction, keyPointer, &output))
        defer {
            yrs_bridge_value_destroy(output)
        }
        return nativeValue(output)
    }
}

private func setXmlAttribute(_ value: YValue, forKey key: String, in xml: OpaquePointer, transaction: OpaquePointer) throws {
    try key.withCString { keyPointer in
        try withNativeValue(value) { nativeValue in
            try throwIfNeeded(yrs_bridge_xml_set_attribute(xml, transaction, keyPointer, nativeValue))
        }
    }
}

private func removeXmlAttribute(_ key: String, from xml: OpaquePointer, transaction: OpaquePointer) throws {
    try key.withCString { keyPointer in
        try throwIfNeeded(yrs_bridge_xml_remove_attribute(xml, transaction, keyPointer))
    }
}

private func jsonString(from attributes: YAttributes, rawScalars: Bool) throws -> String {
    let object = try attributes.mapValues { value in
        try jsonObject(from: value, rawScalars: rawScalars)
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
}

private func jsonString(from delta: [YTextDeltaOperation]) throws -> String {
    let objects = try delta.map { operation -> [String: Any] in
        switch operation {
        case let .retain(length, attributes):
            return [
                "retain": Int(length),
                "attributes": try attributes.mapValues { try jsonObject(from: $0, rawScalars: true) }
            ]
        case let .delete(length):
            return ["delete": Int(length)]
        case let .insert(value, attributes):
            return [
                "insert": try jsonObject(from: value, rawScalars: false),
                "attributes": try attributes.mapValues { try jsonObject(from: $0, rawScalars: true) }
            ]
        }
    }
    let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "[]"
}

private func jsonObject(from value: YValue, rawScalars: Bool) throws -> Any {
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

private func decodeTextChunks(from data: Data) throws -> [YTextChunk] {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let chunks = object as? [[String: Any]] else {
        return []
    }
    return chunks.map { chunk in
        let insert = nativeValue(fromJSONObject: chunk["insert"])
        let attributesObject = chunk["attributes"] as? [String: Any] ?? [:]
        let attributes = attributesObject.mapValues { nativeValue(fromJSONObject: $0) }
        return YTextChunk(insert: insert, attributes: attributes)
    }
}

func nativeValue(fromJSONObject object: Any?) -> YValue {
    guard let object = object as? [String: Any], let tag = object["tag"] as? String else {
        return .undefined
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
            let native = nativeValue(fromJSONObject: value)
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

func nativeValue(_ value: YrsBridgeValue) -> YValue {
    switch value.tag {
    case 1:
        return .null
    case 2:
        return .bool(value.bool_value)
    case 3:
        return .int(value.int_value)
    case 4:
        return .double(value.double_value)
    case 5:
        guard let bytes = value.bytes else {
            return .undefined
        }
        let data = Data(bytes: bytes, count: Int(value.len))
        return .string(String(data: data, encoding: .utf8) ?? "")
    case 6:
        guard let bytes = value.bytes else {
            return .undefined
        }
        return .binary(Data(bytes: bytes, count: Int(value.len)))
    case 7:
        guard let branch = value.branch else {
            return .undefined
        }
        return .text(YText(handle: branch))
    case 8:
        guard let branch = value.branch else {
            return .undefined
        }
        return .map(YMap(handle: branch))
    case 9:
        guard let branch = value.branch else {
            return .undefined
        }
        return .array(YArray(handle: branch))
    case 10:
        return .undefined
    case 11:
        guard let branch = value.branch else {
            return .undefined
        }
        return .xmlFragment(YXmlFragment(handle: branch))
    case 12:
        return .weakLink
    case 13:
        guard let branch = value.branch else {
            return .undefined
        }
        return .xmlElement(YXmlElement(handle: branch))
    case 14:
        guard let branch = value.branch else {
            return .undefined
        }
        return .xmlText(YXmlText(handle: branch))
    default:
        return .undefined
    }
}

private func withNativeValue<T>(_ value: YValue, _ body: (YrsBridgeValue) throws -> T) throws -> T {
    switch value {
    case .undefined:
        return try body(YrsBridgeValue(tag: 0))
    case .null:
        return try body(YrsBridgeValue(tag: 1))
    case let .bool(value):
        return try body(YrsBridgeValue(tag: 2, bool_value: value))
    case let .int(value):
        return try body(YrsBridgeValue(tag: 3, int_value: value))
    case let .double(value):
        return try body(YrsBridgeValue(tag: 4, double_value: value))
    case let .string(value):
        return try value.withCString { pointer in
            let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
            return try body(YrsBridgeValue(tag: 5, bytes: UnsafeMutablePointer(mutating: bytes), len: UInt(value.utf8.count)))
        }
    case let .binary(value):
        return try value.withUnsafeBytes { bytes in
            let pointer = bytes.bindMemory(to: UInt8.self).baseAddress
            return try body(YrsBridgeValue(tag: 6, bytes: UnsafeMutablePointer(mutating: pointer), len: UInt(bytes.count)))
        }
    case let .text(value):
        return try body(YrsBridgeValue(tag: 7, branch: value.handle))
    case let .map(value):
        return try body(YrsBridgeValue(tag: 8, branch: value.handle))
    case let .array(value):
        return try body(YrsBridgeValue(tag: 9, branch: value.handle))
    case .document:
        throw YError.typeMismatch
    case let .xmlFragment(value):
        return try body(YrsBridgeValue(tag: 11, branch: value.handle))
    case let .xmlElement(value):
        return try body(YrsBridgeValue(tag: 13, branch: value.handle))
    case let .xmlText(value):
        return try body(YrsBridgeValue(tag: 14, branch: value.handle))
    case .weakLink:
        return try body(YrsBridgeValue(tag: 12))
    }
}

private extension YrsBridgeValue {
    init(
        tag: Int32 = 0,
        bool_value: Bool = false,
        int_value: Int64 = 0,
        double_value: Double = 0,
        bytes: UnsafeMutablePointer<UInt8>? = nil,
        len: UInt = 0,
        branch: OpaquePointer? = nil
    ) {
        self.init()
        self.tag = tag
        self.bool_value = bool_value
        self.int_value = int_value
        self.double_value = double_value
        self.bytes = bytes
        self.len = len
        self.branch = branch
    }
}
