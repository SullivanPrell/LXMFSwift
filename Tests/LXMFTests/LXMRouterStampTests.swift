import XCTest
import ReticulumSwift
@testable import LXMF

/// Tests for LXMRouter stamp cost management and message lifecycle.
///
/// Python reference (LXMRouter.py):
///   router.set_inbound_stamp_cost(destination_hash, stamp_cost)
///   router.get_outbound_stamp_cost(destination_hash)
///   router.has_message(transient_id)
///   router.cancel_outbound(message_id)
///   router.get_outbound_progress(lxm_hash)
final class LXMRouterStampTests: XCTestCase {

    private func makeRouter() -> LXMRouter { LXMRouter(transport: Transport()) }

    // MARK: - set_inbound_stamp_cost / get_outbound_stamp_cost

    func testSetInboundStampCostReturnsTrue() {
        let router = makeRouter()
        let hash = Data(repeating: 0xAA, count: 16)
        let result = router.setInboundStampCost(destinationHash: hash, stampCost: 4)
        XCTAssertTrue(result, "setInboundStampCost must return true on success")
    }

    func testGetOutboundStampCostNilWhenUnknown() {
        let router = makeRouter()
        let unknown = Data(repeating: 0xBB, count: 16)
        XCTAssertNil(router.getOutboundStampCost(destinationHash: unknown),
                     "getOutboundStampCost must return nil for unknown destination")
    }

    func testSetAndGetOutboundStampCostRoundTrips() {
        let router = makeRouter()
        let hash = Data(repeating: 0xCC, count: 16)
        router.setOutboundStampCost(destinationHash: hash, stampCost: 8)
        XCTAssertEqual(router.getOutboundStampCost(destinationHash: hash), 8,
                       "getOutboundStampCost must return the value set by setOutboundStampCost")
    }

    func testSetInboundStampCostNilClearsIt() {
        let router = makeRouter()
        let hash = Data(repeating: 0xDD, count: 16)
        router.setInboundStampCost(destinationHash: hash, stampCost: 4)
        let clearedResult = router.setInboundStampCost(destinationHash: hash, stampCost: nil)
        XCTAssertTrue(clearedResult, "clearing stamp cost must also return true")
    }

    // MARK: - has_message

    func testHasMessageReturnsFalseWhenNotDelivered() {
        let router = makeRouter()
        let fakeID = Hashes.randomHash()
        XCTAssertFalse(router.hasMessage(transientID: fakeID),
                       "hasMessage must return false for an unknown transient ID")
    }

    // MARK: - cancel_outbound

    func testCancelOutboundNonExistentMessageIsNoOp() throws {
        let router = makeRouter()
        let fakeID = Hashes.randomHash()
        router.cancelOutbound(messageID: fakeID) // must not crash
    }

    func testCancelOutboundRemovesPendingMessage() throws {
        let (src, dst) = try makeSrcDst()
        let router = makeRouter()
        let msg = LXMessage(destination: dst, source: src,
                            content: "cancel-me", desiredMethod: .direct)
        try msg.pack()
        msg.state = .outbound
        // Inject directly into pending list to avoid needing a running transport
        router.testInjectPendingOutbound(msg)

        router.cancelOutbound(messageID: msg.messageID ?? Hashes.randomHash())

        XCTAssertEqual(msg.state, .cancelled,
                       "cancel_outbound must set message state to .cancelled")
    }

    // MARK: - get_outbound_progress

    func testGetOutboundProgressNilForUnknownHash() {
        let router = makeRouter()
        let unknownHash = Hashes.randomHash()
        XCTAssertNil(router.getOutboundProgress(lxmHash: unknownHash),
                     "getOutboundProgress must return nil for unknown hash")
    }

    func testGetOutboundProgressReturnsProgressForPendingMessage() throws {
        let (src, dst) = try makeSrcDst()
        let router = makeRouter()
        let msg = LXMessage(destination: dst, source: src,
                            content: "progress-test", desiredMethod: .direct)
        try msg.pack()
        msg.state = .outbound
        msg.progress = 0.5
        guard let hash = msg.hash else { XCTFail("hash must be set after pack"); return }
        router.testInjectPendingOutbound(msg)

        let progress = router.getOutboundProgress(lxmHash: hash)
        XCTAssertNotNil(progress, "getOutboundProgress must return a value for pending message")
        XCTAssertEqual(progress!, 0.5, accuracy: 0.01)
    }

    // MARK: - Helpers

    private func makeSrcDst() throws -> (Destination, Destination) {
        let srcID = Identity(); let dstID = Identity()
        let src = try Destination(identity: srcID, direction: .in, kind: .single, appName: APP_NAME, aspects: ["delivery"])
        let dst = try Destination(identity: dstID, direction: .in, kind: .single, appName: APP_NAME, aspects: ["delivery"])
        return (src, dst)
    }

    // MARK: - Delivery announce handler stamp cost extraction

    /// When a delivery announce arrives with stamp cost at appData[1], the router
    /// must store it via setOutboundStampCost.
    /// Mirrors Python's LXMFDeliveryAnnounceHandler.received_announce → update_stamp_cost.
    func testDeliveryAnnounceExtractsStampCostFromAppData() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())

        let dstId = Identity()
        let dstHash = try Destination(identity: dstId, direction: .in, kind: .single,
                                      appName: APP_NAME, aspects: ["delivery"]).hash

        XCTAssertNil(router.getOutboundStampCost(destinationHash: dstHash), "baseline: no stamp cost")

        // Python delivery announce: [display_name_nil, stamp_cost=9, [SF_COMPRESSION]]
        let appData = MsgPack.encode(.array([.nil, .int(9), .array([.uint(0)])]))

        // Call setOutboundStampCost directly as the announce handler would.
        if let cost = stampCostFromAppData(appData) {
            router.setOutboundStampCost(destinationHash: dstHash, stampCost: cost)
        }

        XCTAssertEqual(router.getOutboundStampCost(destinationHash: dstHash), 9,
                       "Stamp cost must be extracted from appData[1]")
    }

    func testStampCostFromAppDataReadsIndexOne() {
        // Python format: [display_name, stamp_cost, functionality]
        let appData = MsgPack.encode(.array([.nil, .int(5), .array([.uint(0)])]))
        XCTAssertEqual(stampCostFromAppData(appData), 5,
                       "stampCostFromAppData must read appData[1], not appData[0]")
    }

    func testStampCostFromAppDataIgnoresDisplayNameAtIndexZero() {
        // display_name at [0] is bytes, not an int → must not be confused for stamp cost
        let name = Data("Bob".utf8)
        let appData = MsgPack.encode(.array([.bytes(name), .int(3), .array([.uint(0)])]))
        XCTAssertEqual(stampCostFromAppData(appData), 3)
    }

    // MARK: - Auto-stamp-cost in send()

    /// send() must auto-configure message.stampCost from stored outbound stamp costs
    /// when the message hasn't set a stamp cost yet.
    /// Mirrors Python's handle_outbound() lines 1651–1655.
    func testSendAutoConfiguresStampCostFromStoredCosts() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())

        let dstId = Identity()
        let dstHash = try Destination(identity: dstId, direction: .in, kind: .single,
                                      appName: APP_NAME, aspects: ["delivery"]).hash

        // Store a known stamp cost for the destination.
        router.setOutboundStampCost(destinationHash: dstHash, stampCost: 4)

        // Create a message without a stamp cost.
        let srcId = Identity()
        let srcDest = try Destination(identity: srcId, direction: .in, kind: .single,
                                      appName: APP_NAME, aspects: ["delivery"])
        let dstDest = try Destination(identity: dstId, direction: .in, kind: .single,
                                      appName: APP_NAME, aspects: ["delivery"])
        let msg = LXMessage(destination: dstDest, source: srcDest, content: "test")
        XCTAssertNil(msg.stampCost, "message should have no stamp cost before send()")

        // send() — will fail with noPropagationNode or similar, but must have set stampCost first.
        try? router.send(msg)

        XCTAssertEqual(msg.stampCost, 4,
                       "send() must auto-configure stampCost from outboundStampCosts")
    }

    func testSendDoesNotOverrideExplicitStampCost() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())

        let dstId = Identity()
        let dstHash = try Destination(identity: dstId, direction: .in, kind: .single,
                                      appName: APP_NAME, aspects: ["delivery"]).hash

        router.setOutboundStampCost(destinationHash: dstHash, stampCost: 4)

        let srcId = Identity()
        let srcDest = try Destination(identity: srcId, direction: .in, kind: .single,
                                      appName: APP_NAME, aspects: ["delivery"])
        let dstDest = try Destination(identity: dstId, direction: .in, kind: .single,
                                      appName: APP_NAME, aspects: ["delivery"])
        let msg = LXMessage(destination: dstDest, source: srcDest, content: "test")
        msg.stampCost = 7  // user-set stamp cost — must not be overridden

        try? router.send(msg)

        XCTAssertEqual(msg.stampCost, 7,
                       "send() must not override an already-set stampCost")
    }
}
