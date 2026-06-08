import Foundation
import SwiftYrs

/// Owns the shared chat log and renders it to the terminal.
///
/// The chat log is a top-level `YArray("messages")` whose entries are nested
/// `YMap { sender, body, ts }`. Rendering is append-only: an internal
/// `lastRenderedCount` tracks how many entries have already been printed, and
/// `renderNew()` prints only the entries beyond it. Local writes and remote
/// updates both fire the array observer and flow through the same path, so a
/// peer's own messages echo without any dedup.
actor ChatLog {
    private let doc: YDoc
    private let messages: YArray
    private var lastRenderedCount: UInt32 = 0
    private var live = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(doc: YDoc) throws {
        self.doc = doc
        self.messages = try doc.array(named: "messages")
    }

    /// Prints the last 10 synced messages as history, then seeds
    /// `lastRenderedCount` to the full count and enables live rendering. Called
    /// once after the initial sync settles so history is not re-streamed.
    func showHistoryAndGoLive() async {
        let count = await currentCount()
        let start = count > 10 ? count - 10 : 0
        if start < count {
            print("--- last \(count - start) message(s) ---")
            let lines = await readMessages(start..<count)
            for line in lines { print(line) }
            print("--- end of history ---")
        }
        lastRenderedCount = count
        live = true
    }

    /// Prints any entries appended since the last render. No-op until
    /// `showHistoryAndGoLive()` has run.
    func renderNew() async {
        guard live else { return }
        let count = await currentCount()
        guard count > lastRenderedCount else { return }
        let lines = await readMessages(lastRenderedCount..<count)
        for line in lines { print(line) }
        lastRenderedCount = count
    }

    /// Appends a message authored by `sender` to the shared log.
    func append(sender: String, body: String) {
        let ts = Int64(Date().timeIntervalSince1970)
        try? doc.write { txn in
            let count = try txn.count(of: messages)
            let entry = try txn.insertMap(into: messages, at: count)
            try txn.set(.string(sender), forKey: "sender", in: entry)
            try txn.set(.string(body), forKey: "body", in: entry)
            try txn.set(.int(ts), forKey: "ts", in: entry)
        }
    }

    /// Reads and formats the messages at `range` in a single read transaction.
    ///
    /// The array observer fires *during* the apply transaction of a remote
    /// update, so a read started then throws (yrs permits one transaction at a
    /// time). The write commits within milliseconds, so we retry briefly rather
    /// than drop the update — without this, a peer silently loses messages whose
    /// observer event has no later follow-up.
    private func readMessages(_ range: Range<UInt32>) async -> [String] {
        await retryingRead { txn in
            try range.compactMap { index in
                guard case let .map(entry) = try txn.get(index, from: self.messages) else {
                    return nil
                }
                let sender = Self.string(try txn.get("sender", from: entry))
                let body = Self.string(try txn.get("body", from: entry))
                let ts = Self.int(try txn.get("ts", from: entry))
                let time = Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
                return "[\(time)] \(sender): \(body)"
            }
        } ?? []
    }

    private func currentCount() async -> UInt32 {
        await retryingRead { try $0.count(of: self.messages) } ?? lastRenderedCount
    }

    /// Runs `body` in a read transaction, retrying briefly while a concurrent
    /// write transaction (a remote apply) keeps the read from opening.
    private func retryingRead<T>(_ body: @escaping (YReadTransaction) throws -> T) async -> T? {
        for _ in 0..<100 {
            if let value = try? doc.read(body) {
                return value
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private static func string(_ value: YValue) -> String {
        if case let .string(string) = value { return string }
        return ""
    }

    private static func int(_ value: YValue) -> Int64 {
        if case let .int(int) = value { return int }
        return 0
    }
}
