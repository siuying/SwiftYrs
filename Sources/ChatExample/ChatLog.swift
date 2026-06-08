import Foundation
import SwiftYrs

/// Owns the shared chat log and renders it to the terminal.
///
/// The chat log is a top-level `YArray("messages")` whose entries are nested
/// `YMap { sender, body, ts }`. Rendering is append-only: `lastRenderedCount`
/// tracks how many entries have already been printed, and `renderNew()` prints
/// only the entries beyond it. Local writes and remote updates both fire the
/// array observer and flow through the same path, so a peer's own messages echo
/// without any dedup.
///
/// `renderNew()` is only ever called serially (from a single consuming task,
/// after `showHistory()`), so it needs no reentrancy guard.
actor ChatLog {
    private let doc: YDoc
    private let messages: YArray
    private var lastRenderedCount: UInt32 = 0

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(doc: YDoc) throws {
        self.doc = doc
        self.messages = try doc.array(named: "messages")
    }

    /// Prints the last 10 messages currently in the log as a history block and
    /// seeds `lastRenderedCount` to the full count. Call once, after the initial
    /// sync settles and before streaming live updates, so a joining peer's
    /// synced backlog renders as one block instead of a flood.
    func showHistory() async {
        guard let (count, lines) = await readNew(from: 0, tail: 10) else { return }
        if !lines.isEmpty {
            print("--- last \(lines.count) message(s) ---")
            for line in lines { print(line) }
            print("--- end of history ---")
        }
        lastRenderedCount = count
    }

    /// Prints entries appended since the last render. Advances only on a
    /// successful read, so a transient failure is retried by the next event
    /// rather than silently skipping messages.
    func renderNew() async {
        let start = lastRenderedCount
        guard let (count, lines) = await readNew(from: start, tail: nil), count > start else {
            return
        }
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

    /// Reads the current count and formats the new entries in a single
    /// transaction, returning `(count, lines)`. With `tail`, only the last
    /// `tail` entries are formatted (for history); otherwise every entry from
    /// `from` onward is.
    ///
    /// Returns `nil` only if the read never succeeds: the array observer fires
    /// *during* the apply transaction of a remote update, so a read started then
    /// throws (yrs permits one transaction at a time). The write commits within
    /// milliseconds, so we retry briefly rather than drop the update.
    private func readNew(from start: UInt32, tail: UInt32?) async -> (count: UInt32, lines: [String])? {
        await retryingRead { txn in
            let count = try txn.count(of: self.messages)
            let lower = tail.map { count > $0 ? count - $0 : 0 } ?? start
            guard count > lower else { return (count, []) }
            return (count, try self.format(lower..<count, in: txn))
        }
    }

    private func format(_ range: Range<UInt32>, in txn: YReadTransaction) throws -> [String] {
        try range.compactMap { index in
            guard case let .map(entry) = try txn.get(index, from: messages) else {
                return nil
            }
            let sender = Self.string(try txn.get("sender", from: entry))
            let body = Self.string(try txn.get("body", from: entry))
            let ts = Self.int(try txn.get("ts", from: entry))
            let time = Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
            return "[\(time)] \(sender): \(body)"
        }
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
