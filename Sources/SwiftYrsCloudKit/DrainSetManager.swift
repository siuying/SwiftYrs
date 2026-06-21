#if canImport(CloudKit)
import Foundation

struct DrainSetManager {
    private let metadataStore: CloudKitMetadataStore
    private let documentName: String
    private(set) var drainSet: [UInt64: UInt32] = [:]

    init(metadataStore: CloudKitMetadataStore, documentName: String) {
        self.metadataStore = metadataStore
        self.documentName = documentName
    }

    @discardableResult
    mutating func load() -> [UInt64: UInt32] {
        guard let data = try? metadataStore.data(
            forKey: CloudKitSyncStateKeys.drainSet,
            documentName: documentName
        ), let decoded = try? DrainSetCodec.decode(data) else {
            drainSet = [:]
            return drainSet
        }
        drainSet = decoded
        return drainSet
    }

    mutating func replace(with drainSet: [UInt64: UInt32]) {
        self.drainSet = drainSet
        persist()
    }

    mutating func update(clientID: UInt64, marker: UInt32) {
        drainSet[clientID] = marker
        persist()
    }

    mutating func retire(clientID: UInt64) {
        drainSet[clientID] = nil
        persist()
    }

    mutating func clear() {
        drainSet.removeAll()
        try? metadataStore.removeData(
            forKey: CloudKitSyncStateKeys.drainSet,
            documentName: documentName
        )
    }

    func persist() {
        guard let data = try? DrainSetCodec.encode(drainSet) else { return }
        try? metadataStore.set(
            data,
            forKey: CloudKitSyncStateKeys.drainSet,
            documentName: documentName
        )
    }
}
#endif
