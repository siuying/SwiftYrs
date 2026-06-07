import Foundation
import Testing
import SwiftYrs
import SwiftYrsHocuspocus

@Suite(.serialized)
struct HocuspocusE2ETests {
    @Test
    func providerCommunicatesWithRealHocuspocusServer() async throws {
        let server = try JSONLineProcess.node(script: "hocuspocus-server.ts")
        defer {
            server.stop()
        }
        let ready = try await server.waitForLine(where: { $0["type"] as? String == "ready" })
        let port = try #require(ready["port"] as? Int)
        let url = URL(string: "ws://127.0.0.1:\(port)")!

        let document = YDoc(clientID: 101)
        let text = try document.text(named: "body")
        let awareness = YAwareness(document: document)
        try awareness.setLocalState(["name": "swift"])
        let provider = HocuspocusProvider(url: url, name: "room-e2e", document: document, awareness: awareness)
        var statelessIterator = provider.stateless.makeAsyncIterator()
        try await provider.connect()
        defer {
            Task {
                await provider.disconnect()
            }
        }

        let peer = try JSONLineProcess.node(script: "hocuspocus-peer.ts", arguments: [url.absoluteString, "room-e2e"])
        defer {
            peer.stop()
        }
        _ = try await peer.waitForLine(where: { $0["type"] as? String == "ready" })
        _ = try await peer.waitForLine(where: { $0["type"] as? String == "synced" })

        try await peer.send(["type": "insertText", "text": "hello"])
        try await e2eExpectEventually {
            try document.read { transaction in
                try transaction.string(from: text) == "hello"
            }
        }

        try document.write { transaction in
            try transaction.insert(" swift", into: text, at: 5)
        }
        try await e2eExpectEventually {
            let response = try await peer.request(["type": "getText"], responseType: "text")
            return response["text"] as? String == "hello swift"
        }

        try await e2eExpectEventually {
            let response = try await peer.request(["type": "getAwareness"], responseType: "awareness")
            let states = response["states"] as? [[String: Any]] ?? []
            return states.contains { entry in
                (entry["state"] as? [String: Any])?["name"] as? String == "swift"
            }
        }

        try await peer.send(["type": "sendStateless", "payload": "from-js"])
        let statelessValue = E2EValueBox<String>()
        let statelessTask = Task {
            await statelessValue.set(statelessIterator.next())
        }
        defer {
            statelessTask.cancel()
        }
        try await e2eExpectEventually {
            await statelessValue.value == "from-js"
        }
    }

    @Test
    func providerAuthenticatesWithRealHocuspocusServer() async throws {
        let server = try JSONLineProcess.node(
            script: "hocuspocus-server.ts",
            environment: ["HOCUSPOCUS_AUTH_TOKEN": "secret"]
        )
        defer {
            server.stop()
        }
        let ready = try await server.waitForLine(where: { $0["type"] as? String == "ready" })
        let port = try #require(ready["port"] as? Int)
        let provider = HocuspocusProvider(
            url: URL(string: "ws://127.0.0.1:\(port)")!,
            name: "room-auth",
            document: YDoc(clientID: 102),
            token: { "secret" }
        )
        var authIterator = provider.authStatus.makeAsyncIterator()

        try await provider.connect()
        defer {
            Task {
                await provider.disconnect()
            }
        }

        #expect(await authIterator.next() == .authenticated(scope: "read-write"))
    }
}

private final class JSONLineProcess: @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let outputQueue = DispatchQueue(label: "JSONLineProcess.output")
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

    static func node(
        script: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> JSONLineProcess {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(script)
        process.arguments = ["node", scriptURL.path] + arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.currentDirectoryURL = scriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runner = JSONLineProcess(process: process, input: input, output: output, error: error)
        try process.run()
        return runner
    }

    func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0a])
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(_ object: [String: Any], responseType: String) async throws -> [String: Any] {
        try await send(object)
        return try await waitForLine(where: { $0["type"] as? String == responseType })
    }

    func waitForLine(
        timeout: Duration = .seconds(5),
        where predicate: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let line = outputQueue.sync(execute: {
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
        guard !data.isEmpty else {
            return
        }
        outputQueue.sync {
            buffered.append(data)
            while let newline = buffered.firstIndex(of: 0x0a) {
                let lineData = buffered[..<newline]
                buffered.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else {
                    continue
                }
                lines.append(object)
            }
        }
    }
}

private struct E2ETimeout: Error {}

private actor E2EValueBox<Value: Sendable> {
    private var storage: Value?

    var value: Value? {
        storage
    }

    func set(_ value: Value?) {
        storage = value
    }
}

private func e2eExpectEventually(_ predicate: @escaping () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if try await predicate() {
            return
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    if try await predicate() {
        return
    }
    throw E2ETimeout()
}
