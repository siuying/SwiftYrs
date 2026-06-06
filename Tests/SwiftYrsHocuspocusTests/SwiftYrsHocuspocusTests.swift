import Testing
import Foundation
import SwiftYrs
import SwiftYrsHocuspocus

@Test
func hocuspocusProviderPackageScaffoldIsAvailable() {
    #expect(HocuspocusProvider.productName == "SwiftYrsHocuspocus")
}

@Test
func hocuspocusMessageRoundTripsSyncPayloads() throws {
    let document = YDoc(clientID: 1)
    let syncMessage = try YSyncMessage.syncStep1(document.stateVector())
    let message = HocuspocusMessage.sync(documentName: "room-1", syncMessage)

    let decoded = try HocuspocusMessage.decode(message.encoded())

    #expect(decoded == message)
}

@Test
func hocuspocusMessageRoundTripsAwarenessUpdates() throws {
    let document = YDoc(clientID: 2)
    let awareness = YAwareness(document: document)
    try awareness.setLocalState(["name": "Ada"])
    let update = try awareness.encodeUpdate()
    let message = HocuspocusMessage.awareness(documentName: "room-1", update)

    let decoded = try HocuspocusMessage.decode(message.encoded())

    #expect(decoded == message)
}

@Test
func hocuspocusMessageRoundTripsAuthSubtypes() throws {
    let messages: [HocuspocusMessage] = [
        .auth(documentName: "room-1", .token("secret", version: "SwiftYrsHocuspocus/1")),
        .auth(documentName: "room-1", .permissionDenied(reason: "nope")),
        .auth(documentName: "room-1", .authenticated(scope: "read-write")),
    ]

    for message in messages {
        let decoded = try HocuspocusMessage.decode(message.encoded())
        #expect(decoded == message)
    }
}

@Test
func hocuspocusMessageRoundTripsSimpleMessages() throws {
    let messages: [HocuspocusMessage] = [
        .queryAwareness(documentName: "room-1"),
        .stateless(documentName: "room-1", payload: "ping"),
        .close(documentName: "room-1", reason: "server shutdown"),
        .syncStatus(documentName: "room-1", applied: true),
        .syncStatus(documentName: "room-1", applied: false),
    ]

    for message in messages {
        let decoded = try HocuspocusMessage.decode(message.encoded())
        #expect(decoded == message)
    }
}

@Test
func hocuspocusMessageRejectsMalformedFrames() {
    #expect(throws: HocuspocusCodecError.malformedMessage) {
        try HocuspocusMessage.decode(Data([0xff, 0xff]))
    }

    #expect(throws: HocuspocusCodecError.unsupportedMessageType(99)) {
        try HocuspocusMessage.decode(Data([0x04, 0x72, 0x6f, 0x6f, 0x6d, 99]))
    }
}
