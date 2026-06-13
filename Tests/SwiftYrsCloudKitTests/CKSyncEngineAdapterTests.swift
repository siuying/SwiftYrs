#if canImport(CloudKit)
import CloudKit
import SwiftYrsCloudKit
import Testing

/// The real `CKSyncEngine`-backed adapter is verified for live behavior in the
/// integration step (issue #71). Here we only assert — at compile time — that it
/// conforms to the seam the mock already proves. We deliberately do not
/// instantiate it: constructing a `CKContainer` requires an iCloud entitlement
/// the test host does not have.
@Test
func ckSyncEngineAdapterConformsToTheSeam() {
    func requireSeam<T: CloudKitSyncEngineAdapter>(_ type: T.Type) {}
    requireSeam(CKSyncEngineAdapter.self)
}
#endif
