#if canImport(CloudKit)
import CloudKit

final class RecordQueue: @unchecked Sendable {
    private var records: [CKRecord.ID: CKRecord] = [:]

    func enqueue(_ record: CKRecord) {
        records[record.recordID] = record
    }

    func record(toSave recordID: CKRecord.ID) -> CKRecord? {
        records[recordID]
    }

    func remove(_ recordID: CKRecord.ID) {
        records.removeValue(forKey: recordID)
    }

    func removeAll() {
        records.removeAll()
    }
}
#endif
