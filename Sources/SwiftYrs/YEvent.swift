import Foundation
import YrsBridgeFFI

/// A segment of an observation event's path, from the document root down to the
/// shared type that changed.
public enum YPathSegment: Equatable, Sendable {
    case key(String)
    case index(UInt32)
}

/// The client IDs whose awareness state was added, updated, or removed by an
/// awareness update/change event.
public struct YAwarenessChange: Equatable, Sendable {
    public let added: [UInt64]
    public let updated: [UInt64]
    public let removed: [UInt64]

    public init(added: [UInt64], updated: [UInt64], removed: [UInt64]) {
        self.added = added
        self.updated = updated
        self.removed = removed
    }

    /// Every client ID touched by the event, regardless of bucket.
    public var changed: [UInt64] {
        added + updated + removed
    }
}

/// A change to one entry of a map's keys or an XML element's attributes.
public enum YEventChange: Equatable {
    case inserted(YValue)
    case updated(old: YValue, new: YValue)
    case removed(old: YValue)
}

/// A change reported by observing a shared type (`YText`, `YMap`, `YArray`, XML
/// nodes, weak links).
///
/// `delta` is empty for key-only changes (maps); `keys` is empty for
/// sequence-only changes (text/array); weak-link events carry neither. Array
/// and XML inserts that span several values are flattened into one `.insert`
/// per value, so `delta` is always a `[YTextDeltaOperation]`.
public struct YSharedEvent: Equatable, @unchecked Sendable {
    public enum Target: String, Equatable, Sendable {
        case text, map, array, xml, xmlText, weak
    }

    public let target: Target
    public let path: [YPathSegment]
    public let delta: [YTextDeltaOperation]
    public let keys: [String: YEventChange]

    public init(target: Target, path: [YPathSegment], delta: [YTextDeltaOperation], keys: [String: YEventChange]) {
        self.target = target
        self.path = path
        self.delta = delta
        self.keys = keys
    }
}

/// A typed observation event.
///
/// Replaces the previous JSON-bag accessors: callers `switch` on the case
/// instead of parsing event JSON by key (ADR-0017). The event JSON shape stays
/// internal to this module. `.unknown` guards against shim event kinds added
/// later than this binding.
public enum YEvent: @unchecked Sendable {
    case update(YUpdate)
    case subdocs(added: [String], removed: [String], loaded: [String])
    case transactionCleanup
    case destroy
    case shared(YSharedEvent)
    case awarenessUpdate(YAwarenessChange)
    case awarenessChange(YAwarenessChange)
    case undoItemAdded(action: String)
    case undoItemPopped(action: String)
    case unknown(kind: String)
}

extension YEvent {
    /// Decodes one event from the raw JSON the shim emits to an observation
    /// callback. Unparseable payloads decode to `.unknown("")`.
    init(data: Data) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let kind = object["kind"] as? String ?? ""
        switch kind {
        case "updateV1":
            self = .update(.v1(Data(eventBytes(object["updateV1"]))))
        case "subdocs":
            self = .subdocs(
                added: eventStrings(object["added"]),
                removed: eventStrings(object["removed"]),
                loaded: eventStrings(object["loaded"])
            )
        case "transactionCleanup":
            self = .transactionCleanup
        case "destroy":
            self = .destroy
        case "text", "map", "array", "xml", "xmlText", "weak":
            self = .shared(YSharedEvent(
                target: YSharedEvent.Target(rawValue: kind) ?? .weak,
                path: eventPath(object["path"]),
                delta: YValueCodec.delta(fromJSON: object["delta"]),
                keys: eventKeys(object["keys"])
            ))
        case "awarenessUpdate":
            self = .awarenessUpdate(eventAwarenessChange(object))
        case "awarenessChange":
            self = .awarenessChange(eventAwarenessChange(object))
        case "undoItemAdded":
            self = .undoItemAdded(action: object["action"] as? String ?? "")
        case "undoItemPopped":
            self = .undoItemPopped(action: object["action"] as? String ?? "")
        default:
            self = .unknown(kind: kind)
        }
    }
}

private func eventBytes(_ value: Any?) -> [UInt8] {
    (value as? [Any] ?? []).compactMap { ($0 as? UInt8) ?? ($0 as? NSNumber)?.uint8Value }
}

private func eventStrings(_ value: Any?) -> [String] {
    value as? [String] ?? []
}

private func eventClientIDs(_ value: Any?) -> [UInt64] {
    eventArray(value).compactMap { ($0 as? UInt64) ?? ($0 as? NSNumber)?.uint64Value }
}

private func eventAwarenessChange(_ object: [String: Any]) -> YAwarenessChange {
    YAwarenessChange(
        added: eventClientIDs(object["added"]),
        updated: eventClientIDs(object["updated"]),
        removed: eventClientIDs(object["removed"])
    )
}

private func eventArray(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
}

private func eventUInt32(_ value: Any?) -> UInt32 {
    (value as? UInt32) ?? (value as? NSNumber)?.uint32Value ?? 0
}

private func eventPath(_ value: Any?) -> [YPathSegment] {
    eventArray(value).map { segment in
        if let key = segment as? String {
            return .key(key)
        }
        return .index(eventUInt32(segment))
    }
}

private func eventKeys(_ value: Any?) -> [String: YEventChange] {
    guard let object = value as? [String: Any] else {
        return [:]
    }
    return object.compactMapValues { entry in
        guard let entry = entry as? [String: Any] else {
            return nil
        }
        switch entry["kind"] as? String {
        case "insert":
            return .inserted(YValueCodec.value(fromJSON: entry["value"]))
        case "update":
            return .updated(
                old: YValueCodec.value(fromJSON: entry["oldValue"]),
                new: YValueCodec.value(fromJSON: entry["newValue"])
            )
        case "delete":
            return .removed(old: YValueCodec.value(fromJSON: entry["oldValue"]))
        default:
            return nil
        }
    }
}
