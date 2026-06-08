import Foundation
import SwiftYrs
import SwiftYrsWebRTC

/// A runnable terminal chat that demonstrates `SwiftYrsWebRTC` end to end.
///
/// Peers join a WebRTC mesh through a local signaling server and collaborate on
/// a single shared `YDoc` chat log. Typing a line and pressing Enter appends a
/// message that converges on every connected peer's screen. A newly joining
/// peer syncs the full history, shows the last 10 messages, then streams new
/// ones as they arrive.
///
/// Run with `swift run ChatExample` (see the project README for the
/// start-signaling-then-run-N-terminals flow).
@main
struct ChatExample {
    static func main() async {
        let config: ChatConfig
        do {
            config = try ChatConfig.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            printUsage()
            exit(2)
        }

        do {
            try await run(config)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ config: ChatConfig) async throws {
        let doc = YDoc()
        let log = try ChatLog(doc: doc)

        var options = WebRTCProvider.Options()
        options.password = config.password
        let provider = WebRTCProvider(config.room, doc: doc, signaling: config.signaling, options: options)

        print("Joining room '\(config.room)' as '\(config.name)'")
        print("Signaling: \(config.signaling.map(\.absoluteString).joined(separator: ", "))")
        print("Type a message and press Enter. Use /quit to leave.")

        // Render new entries as the array changes. Local writes and remote
        // updates both fire this observer, so own messages echo via one path.
        let renderTask = Task {
            for await _ in try doc.array(named: "messages").events() {
                await log.renderNew()
            }
        }

        try await provider.connect()

        // Let the initial sync settle, then print the last 10 messages as
        // history and start streaming new ones. Gating on `synced` keeps a
        // joining peer's synced backlog out of the live stream so it renders as
        // one history block; the timeout covers the first peer in a room (which
        // never reaches `synced`) and slow connections. Runs concurrently with
        // input so typing is never blocked while the mesh forms.
        let goLiveTask = Task {
            await awaitInitialSync(provider, timeout: .seconds(8))
            await log.showHistoryAndGoLive()
        }

        // Destroy cleanly on Ctrl-C: remove awareness, tear down signaling and
        // peers, then exit.
        installSIGINTHandler {
            await provider.destroy()
        }

        await readInputLoop(into: log, sender: config.name)

        goLiveTask.cancel()
        renderTask.cancel()
        await provider.destroy()
    }

    /// Reads stdin line by line on a dedicated thread and dispatches each line:
    /// `/`-prefixed lines are commands (`/quit`), everything else is appended
    /// to the chat log as a message. Returns when stdin closes or `/quit`.
    private static func readInputLoop(into log: ChatLog, sender: String) async {
        let lines = AsyncStream<String> { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            thread.stackSize = 1 << 20
            thread.start()
        }

        for await line in lines {
            if line.hasPrefix("/") {
                let command = line.dropFirst().lowercased()
                switch command {
                case "quit":
                    return
                default:
                    print("Unknown command: /\(command)")
                }
                continue
            }
            guard !line.isEmpty else { continue }
            await log.append(sender: sender, body: line)
        }
    }

    /// Waits until the provider reports `synced == true` or `timeout` elapses,
    /// whichever comes first.
    ///
    /// The `synced` watcher cannot live inside a `withTaskGroup`: iterating an
    /// `AsyncStream` does not return on cancellation, so a group (which awaits
    /// all children) would never return on the timeout path — the common case
    /// for the first peer in a room, which never reaches `synced`. Instead the
    /// watcher and timer are unstructured tasks that resume a continuation
    /// exactly once; the watcher is then cancelled and finishes when the stream
    /// ends at `destroy()`.
    private static func awaitInitialSync(_ provider: WebRTCProvider, timeout: Duration) async {
        let once = ResumeOnce()
        let watcher = Task {
            for await value in provider.synced where value {
                once.fire()
                return
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            once.fire()
        }
        await withCheckedContinuation { once.arm($0) }
        watcher.cancel()
        timer.cancel()
    }

    private static func installSIGINTHandler(_ handler: @escaping @Sendable () async -> Void) {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            Task {
                print("\nLeaving…")
                await handler()
                exit(0)
            }
        }
        source.resume()
        // Keep the source alive for the lifetime of the process.
        signalSource = source
    }

    private static func printUsage() {
        let usage = """
        Usage: swift run ChatExample [options]
          --name <string>      sender name (prompted, then user-<uuid>, if omitted)
          --room <string>      room to join (default: chat-demo)
          --signaling <url>    signaling server URL, comma-separated/repeatable
                               (default: ws://127.0.0.1:4444)
          --password <string>  optional shared-room password
        """
        print(usage)
    }
}

/// Retains the SIGINT dispatch source for the process lifetime.
nonisolated(unsafe) private var signalSource: DispatchSourceSignal?

/// Resumes a single `CheckedContinuation` exactly once, whichever of several
/// racing tasks calls `fire()` (or `arm`) first. Thread-safe; later calls are
/// no-ops.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// Stores the continuation, or resumes it immediately if `fire()` already ran.
    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if fired {
            continuation.resume()
        } else {
            self.continuation = continuation
        }
    }

    /// Marks done and resumes the armed continuation, if any. Idempotent.
    func fire() {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }
}
