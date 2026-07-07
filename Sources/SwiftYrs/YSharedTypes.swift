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

/// The base of every shared CRDT type: a live branch in a document, exposed as
/// a reference type per ADR-0002 (copying the Swift object must not suggest
/// copying CRDT content). Equality is branch identity. The branch handle is
/// borrowed from the document and is valid for the document's lifetime
/// (ADR-0015).
public class YSharedType: Equatable {
    let handle: OpaquePointer
    private let bridgeObserve: BridgeObserve

    init(handle: OpaquePointer, observe: @escaping BridgeObserve) {
        self.handle = handle
        self.bridgeObserve = observe
    }

    public static func == (lhs: YSharedType, rhs: YSharedType) -> Bool {
        lhs.handle == rhs.handle
    }

    /// Observes changes to this shared type. The returned token cancels the
    /// observation when cancelled or deallocated.
    public func observe(_ callback: @escaping (YEvent) -> Void) throws -> Observation {
        try registerObservation(handle: handle, observe: bridgeObserve, callback)
    }

    /// An `AsyncStream` of this shared type's change events; the observation is
    /// cancelled when the stream terminates.
    public func events() throws -> AsyncStream<YEvent> {
        try makeEventStream(observe: observe)
    }
}

public final class YText: YSharedType {
    init(handle: OpaquePointer) {
        super.init(handle: handle, observe: yrs_bridge_text_observe)
    }
}

public final class YMap: YSharedType {
    init(handle: OpaquePointer) {
        super.init(handle: handle, observe: yrs_bridge_map_observe)
    }
}

public final class YArray: YSharedType {
    init(handle: OpaquePointer) {
        super.init(handle: handle, observe: yrs_bridge_array_observe)
    }
}

/// An XML node that can hold children: the common API of `YXmlFragment` and
/// `YXmlElement` (child access, child insertion, removal) is defined against
/// this class.
public class YXmlContainer: YSharedType {}

public final class YXmlFragment: YXmlContainer {
    init(handle: OpaquePointer) {
        super.init(handle: handle, observe: yrs_bridge_xml_observe)
    }
}

public final class YXmlElement: YXmlContainer {
    init(handle: OpaquePointer) {
        super.init(handle: handle, observe: yrs_bridge_xml_observe)
    }
}

public final class YXmlText: YSharedType {
    init(handle: OpaquePointer) {
        super.init(handle: handle, observe: yrs_bridge_xml_text_observe)
    }
}

extension YReadTransaction {
    public func length(of text: YText) throws -> UInt32 {
        try readingScalar(UInt32(0)) { yrs_bridge_text_len(text.handle, handle, &$0) }
    }

    public func string(from text: YText) throws -> String {
        let data = try readingBuffer { yrs_bridge_text_string(text.handle, handle, &$0) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func chunks(from text: YText) throws -> [YTextChunk] {
        try YValueCodec.textChunks(from: readingBuffer { yrs_bridge_text_chunks_json(text.handle, handle, &$0) })
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
            return YValueCodec.value(from: output)
        }
    }

    public func entriesJSON(from map: YMap) throws -> [String: Any] {
        let data = try readingBuffer { yrs_bridge_map_entries_json(map.handle, handle, &$0) }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    public func count(of array: YArray) throws -> UInt32 {
        try readingScalar(UInt32(0)) { yrs_bridge_array_len(array.handle, handle, &$0) }
    }

    public func get(_ index: UInt32, from array: YArray) throws -> YValue {
        var output = YrsBridgeValue()
        try throwIfNeeded(yrs_bridge_array_get(array.handle, handle, index, &output))
        defer {
            yrs_bridge_value_destroy(output)
        }
        return YValueCodec.value(from: output)
    }

    public func valuesJSON(from array: YArray) throws -> [Any] {
        let data = try readingBuffer { yrs_bridge_array_values_json(array.handle, handle, &$0) }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [Any] ?? []
    }

    public func childCount(of xml: YXmlContainer) throws -> UInt32 {
        try readingScalar(UInt32(0)) { yrs_bridge_xml_len(xml.handle, handle, &$0) }
    }

    public func string(from xml: YXmlContainer) throws -> String {
        let data = try readingBuffer { yrs_bridge_xml_string(xml.handle, handle, &$0) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func child(at index: UInt32, in xml: YXmlContainer) throws -> YXmlNode {
        var value = YrsBridgeValue()
        try throwIfNeeded(yrs_bridge_xml_get(xml.handle, handle, index, &value))
        defer {
            yrs_bridge_value_destroy(value)
        }
        switch YValueCodec.value(from: value) {
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

    public func tag(of element: YXmlElement) throws -> String {
        let data = try readingBuffer { yrs_bridge_xml_element_tag(element.handle, &$0) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func getAttribute(_ key: String, from xml: YXmlElement) throws -> YValue {
        try xmlAttribute(key, from: xml.handle, transaction: handle)
    }

    /// All of an element's attributes as a natural-JSON object (`{ key: value }`),
    /// for reading a node's full attribute set — including keys the caller does
    /// not know in advance — which per-key `getAttribute` cannot do.
    public func attributesJSON(from xml: YXmlElement) throws -> Data {
        try readingBuffer { yrs_bridge_xml_attributes_json(xml.handle, handle, &$0) }
    }

    public func getAttribute(_ key: String, from xml: YXmlText) throws -> YValue {
        try xmlAttribute(key, from: xml.handle, transaction: handle)
    }

    public func length(of xmlText: YXmlText) throws -> UInt32 {
        try readingScalar(UInt32(0)) { yrs_bridge_xml_text_len(xmlText.handle, handle, &$0) }
    }

    public func string(from xmlText: YXmlText) throws -> String {
        let data = try readingBuffer { yrs_bridge_xml_text_string(xmlText.handle, handle, &$0) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The `YXmlText` content as a natural-JSON delta: UTF-8 JSON encoding an
    /// array of `{ "insert": <string>, "attributes": { ... } }` operations,
    /// matching y-prosemirror's `Y.XmlText.toDelta()`. Attribute values keep
    /// their natural JSON shape (objects intact), which the `YValue`-based
    /// `delta`/`chunks` readers cannot represent — use this for rich formatting
    /// such as ProseMirror marks (`{ "bold": {} }`, `{ "link": { "href": … } }`).
    public func deltaJSON(from xmlText: YXmlText) throws -> Data {
        try readingBuffer { yrs_bridge_xml_text_delta_json(xmlText.handle, handle, &$0) }
    }

    public func subdocGuids() throws -> [String] {
        let data = try readingBuffer { yrs_bridge_transaction_subdoc_guids(handle, &$0) }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String] ?? []
    }

    public func subdoc(forKey key: String, in map: YMap) throws -> YSubdoc {
        try key.withCString { keyPointer in
            let data = try readingBuffer { yrs_bridge_map_get_subdoc_guid(map.handle, handle, keyPointer, &$0) }
            return YSubdoc(guid: String(data: data, encoding: .utf8) ?? "")
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
        let attributes = try YValueCodec.jsonString(from: attributes, rawScalars: true)
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
        let attributes = try YValueCodec.jsonString(from: attributes, rawScalars: true)
        try attributes.withCString { pointer in
            try throwIfNeeded(yrs_bridge_text_format_json(text.handle, handle, index, length, pointer))
        }
    }

    public func insertEmbed(_ value: YValue, into text: YText, at index: UInt32, attributes: YAttributes = [:]) throws {
        let attributes = try YValueCodec.jsonString(from: attributes, rawScalars: true)
        try YValueCodec.withBridgeValue(value) { nativeValue in
            try attributes.withCString { attributesPointer in
                try throwIfNeeded(yrs_bridge_text_insert_embed(text.handle, handle, index, nativeValue, attributesPointer))
            }
        }
    }

    public func applyDelta(_ delta: [YTextDeltaOperation], to text: YText) throws {
        let delta = try YValueCodec.jsonString(from: delta)
        try delta.withCString { pointer in
            try throwIfNeeded(yrs_bridge_text_apply_delta_json(text.handle, handle, pointer))
        }
    }

    public func remove(from text: YText, at index: UInt32, length: UInt32) throws {
        try throwIfNeeded(yrs_bridge_text_remove(text.handle, handle, index, length))
    }

    public func set(_ value: YValue, forKey key: String, in map: YMap) throws {
        try key.withCString { keyPointer in
            try YValueCodec.withBridgeValue(value) { nativeValue in
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
        try YValueCodec.withBridgeValue(value) { nativeValue in
            try throwIfNeeded(yrs_bridge_array_insert(array.handle, handle, index, nativeValue))
        }
    }

    public func insertMap(into array: YArray, at index: UInt32) throws -> YMap {
        try makeBranch(YMap.init) { yrs_bridge_array_insert_map(array.handle, handle, index, &$0) }
    }

    public func insertArray(into array: YArray, at index: UInt32) throws -> YArray {
        try makeBranch(YArray.init) { yrs_bridge_array_insert_array(array.handle, handle, index, &$0) }
    }

    public func setMap(forKey key: String, in map: YMap) throws -> YMap {
        try key.withCString { keyPointer in
            try makeBranch(YMap.init) { yrs_bridge_map_set_map(map.handle, handle, keyPointer, &$0) }
        }
    }

    public func setArray(forKey key: String, in map: YMap) throws -> YArray {
        try key.withCString { keyPointer in
            try makeBranch(YArray.init) { yrs_bridge_map_set_array(map.handle, handle, keyPointer, &$0) }
        }
    }

    public func insertText(into array: YArray, at index: UInt32) throws -> YText {
        try makeBranch(YText.init) { yrs_bridge_array_insert_text(array.handle, handle, index, &$0) }
    }

    public func setText(forKey key: String, in map: YMap) throws -> YText {
        try key.withCString { keyPointer in
            try makeBranch(YText.init) { yrs_bridge_map_set_text(map.handle, handle, keyPointer, &$0) }
        }
    }

    public func remove(from array: YArray, at index: UInt32, length: UInt32) throws {
        try throwIfNeeded(yrs_bridge_array_remove(array.handle, handle, index, length))
    }

    public func insertElement(named name: String, into xml: YXmlContainer, at index: UInt32) throws -> YXmlElement {
        try name.withCString { pointer in
            try makeBranch(YXmlElement.init) { yrs_bridge_xml_insert_element(xml.handle, handle, index, pointer, &$0) }
        }
    }

    public func insertText(into xml: YXmlContainer, at index: UInt32) throws -> YXmlText {
        try makeBranch(YXmlText.init) { yrs_bridge_xml_insert_text(xml.handle, handle, index, &$0) }
    }

    public func remove(from xml: YXmlContainer, at index: UInt32, length: UInt32) throws {
        try throwIfNeeded(yrs_bridge_xml_remove(xml.handle, handle, index, length))
    }

    public func setAttribute(_ value: YValue, forKey key: String, in xml: YXmlElement) throws {
        try setXmlAttribute(value, forKey: key, in: xml.handle, transaction: handle)
    }

    public func setAttribute(_ value: YValue, forKey key: String, in xml: YXmlText) throws {
        try setXmlAttribute(value, forKey: key, in: xml.handle, transaction: handle)
    }

    /// Sets an XML attribute from a natural-JSON value (`valueJSON` is UTF-8
    /// JSON whose shape is preserved, e.g. `[100, 200]` or `{ "a": 1 }`). The
    /// value is stored as a single lib0 `Any` (`ContentAny`), matching how
    /// y-prosemirror stores non-scalar node attributes; a JS peer reads it back
    /// as a plain array/object. Use this for ProseMirror node attrs whose
    /// values are arrays/objects the scalar `YValue` codec cannot carry (e.g. a
    /// prosemirror-tables `colwidth` array). Reads round-trip through
    /// `attributesJSON(from:)`.
    public func setAttribute(json valueJSON: Data, forKey key: String, in xml: YXmlElement) throws {
        try setXmlAttributeJSON(valueJSON, forKey: key, in: xml.handle, transaction: handle)
    }

    public func setAttribute(json valueJSON: Data, forKey key: String, in xml: YXmlText) throws {
        try setXmlAttributeJSON(valueJSON, forKey: key, in: xml.handle, transaction: handle)
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

    /// Inserts `value` carrying inline formatting given as natural JSON
    /// (`attributesJSON` is a UTF-8 JSON object whose values keep their shape,
    /// e.g. `{ "bold": {}, "link": { "href": "…" } }`). Use this for ProseMirror
    /// marks, whose attribute values are objects the `YValue` codec cannot carry.
    public func insert(_ value: String, into xmlText: YXmlText, at index: UInt32, attributesJSON: Data) throws {
        try value.withCString { valuePointer in
            try withJSONCString(attributesJSON) { attributesPointer in
                try throwIfNeeded(
                    yrs_bridge_xml_text_insert_with_attributes_json(
                        xmlText.handle,
                        handle,
                        index,
                        valuePointer,
                        attributesPointer
                    )
                )
            }
        }
    }

    /// Formats an existing range with inline attributes given as natural JSON.
    public func format(_ xmlText: YXmlText, at index: UInt32, length: UInt32, attributesJSON: Data) throws {
        try withJSONCString(attributesJSON) { pointer in
            try throwIfNeeded(yrs_bridge_xml_text_format_json(xmlText.handle, handle, index, length, pointer))
        }
    }

    /// Applies a natural-JSON delta (`[{ "retain"/"insert"/"delete", "attributes" }]`)
    /// to a `YXmlText`, with attribute values kept as their natural JSON.
    public func applyDeltaJSON(_ deltaJSON: Data, to xmlText: YXmlText) throws {
        try withJSONCString(deltaJSON) { pointer in
            try throwIfNeeded(yrs_bridge_xml_text_apply_delta_json(xmlText.handle, handle, pointer))
        }
    }

    public func remove(from xmlText: YXmlText, at index: UInt32, length: UInt32) throws {
        try throwIfNeeded(yrs_bridge_xml_text_remove(xmlText.handle, handle, index, length))
    }

    public func setNewSubdoc(forKey key: String, in map: YMap) throws -> YSubdoc {
        try key.withCString { keyPointer in
            let data = try readingBuffer { yrs_bridge_map_set_new_subdoc(map.handle, handle, keyPointer, &$0) }
            return YSubdoc(guid: String(data: data, encoding: .utf8) ?? "")
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

private func xmlAttribute(_ key: String, from xml: OpaquePointer, transaction: OpaquePointer) throws -> YValue {
    try key.withCString { keyPointer in
        var output = YrsBridgeValue()
        try throwIfNeeded(yrs_bridge_xml_get_attribute(xml, transaction, keyPointer, &output))
        defer {
            yrs_bridge_value_destroy(output)
        }
        return YValueCodec.value(from: output)
    }
}

private func setXmlAttribute(_ value: YValue, forKey key: String, in xml: OpaquePointer, transaction: OpaquePointer) throws {
    try key.withCString { keyPointer in
        try YValueCodec.withBridgeValue(value) { nativeValue in
            try throwIfNeeded(yrs_bridge_xml_set_attribute(xml, transaction, keyPointer, nativeValue))
        }
    }
}

private func setXmlAttributeJSON(_ valueJSON: Data, forKey key: String, in xml: OpaquePointer, transaction: OpaquePointer) throws {
    try key.withCString { keyPointer in
        try withJSONCString(valueJSON) { valuePointer in
            try throwIfNeeded(yrs_bridge_xml_set_attribute_json(xml, transaction, keyPointer, valuePointer))
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
        try YValueCodec.jsonObject(from: value, rawScalars: rawScalars)
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
                "attributes": try attributes.mapValues { try YValueCodec.jsonObject(from: $0, rawScalars: true) }
            ]
        case let .delete(length):
            return ["delete": Int(length)]
        case let .insert(value, attributes):
            return [
                "insert": try YValueCodec.jsonObject(from: value, rawScalars: false),
                "attributes": try attributes.mapValues { try YValueCodec.jsonObject(from: $0, rawScalars: true) }
            ]
        }
    }
    let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "[]"
}

private func decodeTextChunks(from data: Data) throws -> [YTextChunk] {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let chunks = object as? [[String: Any]] else {
        return []
    }
    return chunks.map { chunk in
        let insert = YValueCodec.value(fromJSON: chunk["insert"])
        let attributesObject = chunk["attributes"] as? [String: Any] ?? [:]
        let attributes = attributesObject.mapValues { YValueCodec.value(fromJSON: $0) }
        return YTextChunk(insert: insert, attributes: attributes)
    }
}

/// Passes UTF-8 `json` to a C function expecting a NUL-terminated string. JSON
/// never contains an interior NUL, so the bytes are forwarded verbatim with a
/// terminator appended — no intermediate `String` round-trip.
private func withJSONCString<R>(_ json: Data, _ body: (UnsafePointer<CChar>) throws -> R) throws -> R {
    var bytes = [UInt8](json)
    bytes.append(0)
    return try bytes.withUnsafeBytes { raw in
        try body(raw.bindMemory(to: CChar.self).baseAddress!)
    }
}
