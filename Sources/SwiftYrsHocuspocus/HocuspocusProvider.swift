import Foundation
import SwiftYrs

public enum ConnectionStatus: Equatable, Sendable {
    case connecting
    case connected
    case disconnected
}

protocol HocuspocusWebSocket: Sendable {
    func resume()
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

public actor HocuspocusProvider {
    public static let productName = "SwiftYrsHocuspocus"

    public nonisolated let connectionStatus: AsyncStream<ConnectionStatus>
    public nonisolated let isSynced: AsyncStream<Bool>

    private let url: URL
    private let name: String
    private let document: YDoc
    private let awareness: YAwareness?
    private let token: (@Sendable () async throws -> String)?
    private let maxRetries: Int
    private let initialDelay: Duration
    private let maxDelay: Duration
    private let webSocketFactory: @Sendable (URL) -> any HocuspocusWebSocket
    private let connectionStatusContinuation: AsyncStream<ConnectionStatus>.Continuation
    private let isSyncedContinuation: AsyncStream<Bool>.Continuation
    private var webSocket: (any HocuspocusWebSocket)?
    private var receiveTask: Task<Void, Never>?
    private var documentObservation: Observation?
    private var suppressedRemoteUpdates = Set<Data>()

    public init(
        url: URL,
        name: String,
        document: YDoc,
        awareness: YAwareness? = nil,
        token: (@Sendable () async throws -> String)? = nil,
        maxRetries: Int = .max,
        initialDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30)
    ) {
        self.init(
            url: url,
            name: name,
            document: document,
            awareness: awareness,
            token: token,
            maxRetries: maxRetries,
            initialDelay: initialDelay,
            maxDelay: maxDelay,
            webSocketFactory: { url in
                URLSessionHocuspocusWebSocket(url: url)
            }
        )
    }

    init(
        url: URL,
        name: String,
        document: YDoc,
        awareness: YAwareness? = nil,
        token: (@Sendable () async throws -> String)? = nil,
        maxRetries: Int = .max,
        initialDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(30),
        webSocketFactory: @escaping @Sendable (URL) -> any HocuspocusWebSocket
    ) {
        self.url = url
        self.name = name
        self.document = document
        self.awareness = awareness
        self.token = token
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.webSocketFactory = webSocketFactory

        let connectionStatusPair = AsyncStream.makeStream(of: ConnectionStatus.self)
        self.connectionStatus = connectionStatusPair.stream
        self.connectionStatusContinuation = connectionStatusPair.continuation

        let isSyncedPair = AsyncStream.makeStream(of: Bool.self)
        self.isSynced = isSyncedPair.stream
        self.isSyncedContinuation = isSyncedPair.continuation
    }

    public func connect() async throws {
        connectionStatusContinuation.yield(.connecting)
        let webSocket = webSocketFactory(url)
        self.webSocket = webSocket
        webSocket.resume()
        connectionStatusContinuation.yield(.connected)
        documentObservation = try document.observeUpdates { [weak self] event in
            guard let update = Self.update(from: event) else {
                return
            }
            Task {
                await self?.sendLocalUpdate(update)
            }
        }

        let syncStep1 = try YSyncMessage.syncStep1(document.stateVector())
        try await webSocket.send(HocuspocusMessage.sync(documentName: name, syncStep1).encoded())

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        documentObservation?.cancel()
        documentObservation = nil
        webSocket?.close()
        webSocket = nil
        connectionStatusContinuation.yield(.disconnected)
    }

    private func receiveLoop() async {
        guard let webSocket else {
            return
        }
        do {
            while !Task.isCancelled {
                let data = try await webSocket.receive()
                try handle(data)
            }
        } catch is CancellationError {
        } catch {
            connectionStatusContinuation.yield(.disconnected)
        }
    }

    private func handle(_ data: Data) throws {
        let message = try HocuspocusMessage.decode(data)
        guard case let .sync(_, syncMessage) = message else {
            return
        }
        switch syncMessage {
        case let .syncStep2(update, _):
            try applyRemote(update)
            isSyncedContinuation.yield(true)
        case let .update(update, _):
            try applyRemote(update)
        default:
            return
        }
    }

    private func sendLocalUpdate(_ update: YUpdate) async {
        if suppressedRemoteUpdates.remove(update.data) != nil {
            return
        }
        guard let webSocket else {
            return
        }
        do {
            let syncMessage = try YSyncMessage.update(update)
            try await webSocket.send(HocuspocusMessage.sync(documentName: name, syncMessage).encoded())
        } catch {}
    }

    private func applyRemote(_ update: YUpdate) throws {
        suppressedRemoteUpdates.insert(update.data)
        do {
            try document.write(origin: "SwiftYrsHocuspocus") { transaction in
                try transaction.apply(update)
            }
        } catch {
            suppressedRemoteUpdates.remove(update.data)
            throw error
        }
    }

    private nonisolated static func update(from event: YObservationEvent) -> YUpdate? {
        guard event.kind == "updateV1" else {
            return nil
        }
        let bytes = event.array("updateV1").compactMap { value -> UInt8? in
            if let value = value as? UInt8 {
                return value
            }
            return (value as? NSNumber)?.uint8Value
        }
        guard !bytes.isEmpty else {
            return nil
        }
        return .v1(Data(bytes))
    }
}

private final class URLSessionHocuspocusWebSocket: HocuspocusWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        self.task = URLSession.shared.webSocketTask(with: url)
    }

    func resume() {
        task.resume()
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        let message = try await task.receive()
        switch message {
        case let .data(data):
            return data
        case let .string(string):
            guard let data = string.data(using: .utf8) else {
                throw HocuspocusCodecError.malformedMessage
            }
            return data
        @unknown default:
            throw HocuspocusCodecError.malformedMessage
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
