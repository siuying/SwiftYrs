import Foundation
import Testing
import StreamWebRTC
@testable import SwiftYrsWebRTC

/// Headless peer-to-peer: two `WebRTCConn`s signal straight into each other over
/// host candidates — no signaling server, no browser — while the end-of-candidates
/// sentinel a browser trickles (an empty candidate string) is injected in both
/// directions, before and after the remote description is set.
extension RealNetworkE2E {
    @Suite(.serialized)
    struct WebRTCConnLoopbackTests {
        actor Inbox {
            private var messages: [Data] = []
            var received: [Data] { messages }
            func append(_ data: Data) { messages.append(data) }
        }

        @Test
        func peersExchangeMessagesWhileEndOfCandidatesSentinelsArrive() async throws {
            let factory = WebRTCFactory.makePeerConnectionFactory()
            let initiator = WebRTCConn(remotePeerId: "responder", initiator: true, iceServers: [], factory: factory)
            let responder = WebRTCConn(remotePeerId: "initiator", initiator: false, iceServers: [], factory: factory)
            defer { initiator.close(); responder.close() }

            let endOfCandidates = PeerSignal.candidate(.init(candidate: "", sdpMid: "0", sdpMLineIndex: 0))
            initiator.onSignal = { signal in
                responder.signal(signal)
                responder.signal(endOfCandidates)
            }
            responder.onSignal = { signal in
                initiator.signal(signal)
                initiator.signal(endOfCandidates)
            }
            let atInitiator = Inbox()
            let atResponder = Inbox()
            initiator.onData = { data in Task { await atInitiator.append(data) } }
            responder.onData = { data in Task { await atResponder.append(data) } }
            let initiatorConnected = E2EBox<Bool>()
            let responderConnected = E2EBox<Bool>()
            initiator.onConnected = { Task { await initiatorConnected.set(true) } }
            responder.onConnected = { Task { await responderConnected.set(true) } }

            initiator.signal(endOfCandidates)
            responder.signal(endOfCandidates)
            initiator.start()

            try await e2eEventually("both data channels opened", timeout: .seconds(15)) {
                let initiatorIsOpen = await initiatorConnected.value == true
                let responderIsOpen = await responderConnected.value == true
                return initiatorIsOpen && responderIsOpen
            }

            #expect(await initiator.sendAndFlush(Data("local change".utf8), timeout: .seconds(2)))
            #expect(await responder.sendAndFlush(Data("remote change".utf8), timeout: .seconds(2)))

            try await e2eEventually("both directions delivered", timeout: .seconds(5)) {
                let atResponderReceived = await atResponder.received
                let atInitiatorReceived = await atInitiator.received
                return atResponderReceived == [Data("local change".utf8)]
                    && atInitiatorReceived == [Data("remote change".utf8)]
            }
        }
    }
}
