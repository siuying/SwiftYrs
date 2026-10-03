import Foundation
import Testing

// Opt-in reproduction of synchronous waiters occupying Swift Testing workers.
// The release thread is independent of both Dispatch and the cooperative pool.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTYRS_COOPERATIVE_LOAD"] == "1"), arguments: Array(0..<64))
func cooperativePoolLoad(_ worker: Int) async {
    blockCooperativeWorker()
}

private func blockCooperativeWorker() {
    let released = DispatchSemaphore(value: 0)
    Thread {
        Thread.sleep(forTimeInterval: 3)
        released.signal()
    }.start()
    released.wait()
}
