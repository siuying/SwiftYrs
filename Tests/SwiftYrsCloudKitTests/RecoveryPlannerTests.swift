import Foundation
import SwiftYrs
import SwiftYrsCloudKit
import Testing

@Test
func recoveryResendsOutstandingDiffForOneOpenClient() throws {
    let doc = try documentWithWriters([1: "one"])
    let planner = RecoveryPlanner()

    let plan = try planner.plan(openClients: [1: 0], in: doc)

    #expect(plan.retired.isEmpty)
    #expect(plan.resends.count == 1)
    let resend = try #require(plan.resends.first)
    #expect(resend.clientID == 1)
    #expect(resend.fromClock == 0)

    // The re-sent diff converges a fresh doc on the writer's content.
    let destination = YDoc()
    let text = try destination.text(named: "body")
    try destination.apply(resend.update)
    try destination.read { try #expect($0.string(from: text) == "one") }
}

@Test
func recoveryDrainsMultipleOpenClientsFromChainedCrash() throws {
    let doc = try documentWithWriters([1: "one", 2: "two", 3: "three"])
    let planner = RecoveryPlanner()

    // Clients 2 and 3 are both still open (a crash before either confirmed).
    let plan = try planner.plan(openClients: [2: 0, 3: 0], in: doc)

    #expect(plan.retired.isEmpty)
    #expect(plan.resends.map(\.clientID) == [2, 3]) // ordered by clientID
}

@Test
func recoveryRetiresClientWhoseDiffIsEmpty() throws {
    let doc = try documentWithWriters([1: "one"])
    let planner = RecoveryPlanner()
    let currentClock = try doc.clientClock(clientID: 1)

    // Marker already at the current clock → nothing outstanding → retire.
    let plan = try planner.plan(openClients: [1: currentClock], in: doc)

    #expect(plan.resends.isEmpty)
    #expect(plan.retired == [1])
}

@Test
func recoveryRetiresClientThatNeverWroteToTheDoc() throws {
    let doc = try documentWithWriters([1: "one"])
    let planner = RecoveryPlanner()

    // Client 99 is in the open set but authored nothing in this doc.
    let plan = try planner.plan(openClients: [1: 0, 99: 0], in: doc)

    #expect(plan.resends.map(\.clientID) == [1])
    #expect(plan.retired == [99])
}

@Test
func recoveryReturnsEmptyPlanForEmptyOpenSet() throws {
    let doc = try documentWithWriters([1: "one"])
    let planner = RecoveryPlanner()

    let plan = try planner.plan(openClients: [:], in: doc)

    #expect(plan == RecoveryPlan(resends: [], retired: []))
}

private func documentWithWriters(_ writers: [UInt64: String]) throws -> YDoc {
    let merged = YDoc()
    for clientID in writers.keys.sorted() {
        let writer = YDoc(clientID: clientID)
        let text = try writer.text(named: "body")
        try writer.write { try $0.insert(writers[clientID]!, into: text, at: 0) }
        try merged.apply(try writer.encodeStateAsUpdateV1())
    }
    return merged
}
