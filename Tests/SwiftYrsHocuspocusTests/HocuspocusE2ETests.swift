import Foundation
import Testing
import SwiftYrs
import SwiftYrsHocuspocus

@Suite(.serialized)
struct HocuspocusE2ETests {
    @Test
    func providerCommunicatesWithRealHocuspocusServer() async throws {
        try await withE2EProcesses { processes in
            let server = try processes.node(script: "hocuspocus-server.ts")
            let ready = try await server.waitForLine(where: { $0["type"] as? String == "ready" })
            let port = try #require(ready["port"] as? Int)
            let url = URL(string: "ws://127.0.0.1:\(port)")!

            let document = YDoc(clientID: 101)
            let text = try document.text(named: "body")
            let awareness = YAwareness(document: document)
            try awareness.setLocalState(["name": "swift"])
            let provider = HocuspocusProvider(url: url, name: "room-e2e", document: document, awareness: awareness)
            let statelessValue = E2EValueBox<String>()

            try await withE2EDisconnect([provider]) {
                try await provider.connect()

                let peer = try processes.node(script: "hocuspocus-peer.ts", arguments: [url.absoluteString, "room-e2e"])
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
                let statelessTask = Task {
                    var iterator = provider.stateless.makeAsyncIterator()
                    await statelessValue.set(iterator.next())
                }
                defer {
                    statelessTask.cancel()
                }
                try await e2eExpectEventually {
                    await statelessValue.value == "from-js"
                }
            }
        }
    }

    @Test
    func providerAuthenticatesWithRealHocuspocusServer() async throws {
        try await withE2EProcesses { processes in
            let server = try processes.node(
                script: "hocuspocus-server.ts",
                environment: ["HOCUSPOCUS_AUTH_TOKEN": "secret"]
            )
            let ready = try await server.waitForLine(where: { $0["type"] as? String == "ready" })
            let port = try #require(ready["port"] as? Int)
            let provider = HocuspocusProvider(
                url: URL(string: "ws://127.0.0.1:\(port)")!,
                name: "room-auth",
                document: YDoc(clientID: 102),
                token: { "secret" }
            )
            try await withE2EDisconnect([provider]) {
                try await provider.connect()
                var authIterator = provider.authStatus.makeAsyncIterator()
                #expect(await authIterator.next() == .authenticated(scope: "read-write"))
            }
        }
    }

    @Test
    func destroyDeliversAwarenessRemovalBeforeClose() async throws {
        try await withE2EProcesses { processes in
            let server = try processes.node(
                script: "hocuspocus-server.ts",
                environment: ["HOCUSPOCUS_TRACE": "1"]
            )
            let ready = try await server.waitForLine("server ready", where: { $0["type"] as? String == "ready" })
            let port = try #require(ready["port"] as? Int)

            let document = YDoc(clientID: 130)
            let awareness = YAwareness(document: document)
            try awareness.setLocalState(["name": "leaving"])
            let provider = HocuspocusProvider(
                url: URL(string: "ws://127.0.0.1:\(port)")!,
                name: "room-destroy", document: document, awareness: awareness
            )
            try await withE2EDisconnect([provider]) {
                try await provider.connect()
                _ = try await server.waitForLine("initial awareness", where: { awarenessFrame($0, clientID: 130) { $0 != "null" } })

                await provider.destroy()
                let close = try await server.waitForLine("close", where: { $0["type"] as? String == "close" })
                let removal = try await server.waitForLine("null awareness", where: { awarenessFrame($0, clientID: 130) { $0 == "null" } })
                let removalSequence = try #require(removal["sequence"] as? Int)
                let closeSequence = try #require(close["sequence"] as? Int)
                #expect(removalSequence < closeSequence)
            }
        }
    }
}

private func awarenessFrame(_ line: [String: Any], clientID: Int, state: (String) -> Bool) -> Bool {
    guard line["type"] as? String == "awarenessFrame", let clients = line["clients"] as? [[String: Any]] else {
        return false
    }
    return clients.contains { $0["clientID"] as? Int == clientID && ($0["state"] as? String).map(state) == true }
}

/// Runs `body`, then awaits `disconnect()` on every provider before returning or rethrowing.
private func withE2EDisconnect<A>(
    _ providers: [HocuspocusProvider],
    _ body: () async throws -> A
) async throws -> A {
    var result: Result<A, any Error>!
    do {
        result = .success(try await body())
    } catch {
        result = .failure(error)
    }
    for provider in providers {
        await provider.disconnect()
    }
    return try result.get()
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
            let data = handle.availableData
            guard !data.isEmpty, let self else {
                handle.readabilityHandler = nil
                return
            }
            self.append(data)
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
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
        _ stage: String = "line",
        timeout: Duration = .seconds(30),
        where predicate: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let line = outputQueue.sync(execute: {
                if let index = lines.firstIndex(where: predicate) {
                    return lines.remove(at: index)
                }
                return nil
            }) {
                return line
            }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw E2ETimeout(stage: stage)
    }

    private let teardownQueue = DispatchQueue(label: "JSONLineProcess.teardown")

    func stop() {
        teardownQueue.async { self.stopOnTeardownQueue() }
    }

    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            teardownQueue.async {
                self.stopOnTeardownQueue()
                continuation.resume()
            }
        }
    }

    private func stopOnTeardownQueue() {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data("shutdown\n".utf8))
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
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

private struct E2ETimeout: Error {
    var stage = "condition"
}

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
    let deadline = ContinuousClock.now + .seconds(30)
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

private final class E2EProcesses {
    private var processes: [JSONLineProcess] = []
    func node(script: String, arguments: [String] = [], environment: [String: String] = [:]) throws -> JSONLineProcess {
        let process = try JSONLineProcess.node(script: script, arguments: arguments, environment: environment)
        processes.append(process)
        return process
    }
    func stop() async {
        for process in processes.reversed() { await process.stopAndWait() }
    }
}

private func withE2EProcesses(_ body: (E2EProcesses) async throws -> Void) async throws {
    let processes = E2EProcesses()
    do {
        try await body(processes)
    } catch {
        await processes.stop()
        throw error
    }
    await processes.stop()
}
