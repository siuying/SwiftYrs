import Foundation
@testable import SwiftYrsWebRTC

struct E2ETimeout: Error {
    let description: String?
    init(_ description: String? = nil) { self.description = description }
}

actor E2EBox<Value: Sendable> {
    private var storage: Value?
    var value: Value? { storage }
    func set(_ value: Value?) { storage = value }
}

func e2eEventually(
    _ description: String,
    timeout: Duration,
    _ predicate: @escaping () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    if try await predicate() { return }
    throw E2ETimeout(description)
}

/// Runs `body`, then awaits `destroy()` on every provider before returning or rethrowing.
/// Serialized E2E tests must use this (not fire-and-forget `Task { await destroy() }`) so
/// the next test does not start while prior WebRTC/signaling resources are still live.
func withE2ETeardown<A>(
    _ providers: [WebRTCProvider],
    _ body: () async throws -> A
) async throws -> A {
    var result: Result<A, any Error>!
    do {
        result = .success(try await body())
    } catch {
        result = .failure(error)
    }
    for provider in providers {
        await provider.destroy()
    }
    return try result.get()
}

/// Spawns a Node.js script that speaks newline-delimited JSON over stdio,
/// buffering its stdout lines and forwarding commands on stdin.
final class JSONLineProcess: @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let queue = DispatchQueue(label: "JSONLineProcess.output")
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

    static func node(script: String, arguments: [String] = []) throws -> JSONLineProcess {
        let process = Process()
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(script)
        process.arguments = ["node", scriptURL.path] + arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.environment = ProcessInfo.processInfo.environment
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

    func request(
        _ object: [String: Any],
        responseType: String,
        timeout: Duration = .seconds(5)
    ) async throws -> [String: Any] {
        try await send(object)
        return try await waitForLine("received \(responseType) response", timeout: timeout) {
            $0["type"] as? String == responseType
        }
    }

    func waitForLine(
        _ description: String? = nil,
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
        throw E2ETimeout(description)
    }

    func stop() {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data("{\"type\":\"shutdown\"}\nshutdown\n".utf8))
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
