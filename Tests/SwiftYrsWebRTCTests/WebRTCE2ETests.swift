import Foundation
import Testing
import SwiftYrs
@testable import SwiftYrsWebRTC

@Suite(.serialized)
struct WebRTCE2ETests {
    @Test
    func twoSwiftProvidersSyncADocumentOverADataChannel() async throws {
        let server = try SignalingServerProcess.start()
        defer { server.stop() }
        let ready = try await server.waitForLine { $0["type"] as? String == "ready" }
        let port = try #require(ready["port"] as? Int)
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))

        let docA = YDoc(clientID: 1)
        let textA = try docA.text(named: "body")
        let providerA = WebRTCProvider("room-e2e", doc: docA, signaling: [url], options: loopbackOptions())

        let docB = YDoc(clientID: 2)
        let textB = try docB.text(named: "body")
        let providerB = WebRTCProvider("room-e2e", doc: docB, signaling: [url], options: loopbackOptions())

        // Observe peer A's synced stream to prove it latches true (not vacuously).
        let syncedBox = E2EBox<Bool>()
        let syncedTask = Task { [stream = providerA.synced] in
            for await value in stream { await syncedBox.set(value) }
        }
        defer { syncedTask.cancel() }

        try await providerA.connect()
        try await providerB.connect()
        defer {
            Task { await providerA.destroy() }
            Task { await providerB.destroy() }
        }

        // The mesh establishes a direct data-channel connection over loopback.
        try await e2eEventually(timeout: .seconds(20)) {
            let a = await providerA.connectedPeers
            let b = await providerB.connectedPeers
            return !a.isEmpty && !b.isEmpty
        }

        // An edit on A converges on B.
        try docA.write { try $0.insert("hello", into: textA, at: 0) }
        try await e2eEventually(timeout: .seconds(20)) {
            try docB.read { try $0.string(from: textB) == "hello" }
        }

        // And an edit on B converges on A (bidirectional).
        try docB.write { try $0.insert(" world", into: textB, at: 5) }
        try await e2eEventually(timeout: .seconds(20)) {
            try docA.read { try $0.string(from: textA) == "hello world" }
        }

        // `synced` latched true once a peer completed initial sync.
        try await e2eEventually(timeout: .seconds(5)) {
            await syncedBox.value == true
        }
    }

    @Test
    func destroyBroadcastsOwnedAwarenessRemoval() async throws {
        let server = try SignalingServerProcess.start()
        defer { server.stop() }
        let ready = try await server.waitForLine { $0["type"] as? String == "ready" }
        let port = try #require(ready["port"] as? Int)
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))

        let providerA = WebRTCProvider(
            "room-awareness-removal", doc: YDoc(clientID: 11), signaling: [url], options: loopbackOptions()
        )
        let providerB = WebRTCProvider(
            "room-awareness-removal", doc: YDoc(clientID: 22), signaling: [url], options: loopbackOptions()
        )
        defer {
            Task { await providerB.destroy() }
        }

        try await providerA.connect()
        try await providerB.connect()
        try await e2eEventually(timeout: .seconds(20)) {
            let a = await providerA.connectedPeers
            let b = await providerB.connectedPeers
            return !a.isEmpty && !b.isEmpty
        }

        let awarenessA = await providerA.awareness
        let awarenessB = await providerB.awareness
        let clientID = awarenessA.clientID
        try awarenessA.setLocalState(["name": "swift"])
        try await e2eEventually(timeout: .seconds(5)) {
            try awarenessB.state(for: clientID) != nil
        }

        await providerA.destroy()

        try await e2eEventually(timeout: .seconds(5)) {
            try awarenessB.state(for: clientID) == nil
        }
    }

    private func loopbackOptions() -> WebRTCProvider.Options {
        // No STUN: host candidates over loopback are enough for two local peers.
        WebRTCProvider.Options(iceServers: [])
    }
}

// MARK: - E2E harness

private actor E2EBox<Value: Sendable> {
    private var storage: Value?
    var value: Value? { storage }
    func set(_ value: Value?) { storage = value }
}

private struct E2ETimeout: Error {}

private func e2eEventually(
    timeout: Duration,
    _ predicate: @escaping () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    if try await predicate() { return }
    throw E2ETimeout()
}

/// Spawns the Bun signaling server and exposes its newline-JSON stdout.
private final class SignalingServerProcess: @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let queue = DispatchQueue(label: "SignalingServerProcess")
    private var buffered = Data()
    private var lines: [[String: Any]] = []

    private init(process: Process, input: Pipe, output: Pipe, error: Pipe) {
        self.process = process
        self.input = input
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData)
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                fputs(text, stderr)
            }
        }
    }

    static func start() throws -> SignalingServerProcess {
        let process = Process()
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("webrtc-signaling-server.ts")
        process.arguments = ["bun", script.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.environment = ProcessInfo.processInfo.environment
        let runner = SignalingServerProcess(process: process, input: input, output: output, error: error)
        try process.run()
        return runner
    }

    func waitForLine(
        timeout: Duration = .seconds(5),
        where predicate: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let line = queue.sync(execute: {
                if let index = lines.firstIndex(where: predicate) {
                    return lines.remove(at: index)
                }
                return nil
            }) {
                return line
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw E2ETimeout()
    }

    func stop() {
        if process.isRunning {
            try? input.fileHandleForWriting.write(contentsOf: Data("shutdown\n".utf8))
            process.terminate()
        }
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.sync {
            buffered.append(data)
            while let newline = buffered.firstIndex(of: 0x0a) {
                let lineData = buffered[..<newline]
                buffered.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] {
                    lines.append(object)
                }
            }
        }
    }
}
