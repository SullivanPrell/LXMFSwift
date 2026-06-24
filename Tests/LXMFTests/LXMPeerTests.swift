import XCTest
@testable import LXMF
import ReticulumSwift

/// Tests for LXMPeer — propagation peer state machine, serialization, message tracking.
final class LXMPeerTests: XCTestCase {

    private func makeRouter() -> LXMRouter { LXMRouter(transport: Transport()) }

    private func fakeHash(_ byte: UInt8 = 0xAA) -> Data {
        // Destination hashes are 16 bytes (128 bits truncated hash)
        Data(repeating: byte, count: LXMessage.destinationLength)
    }

    // MARK: - State constants

    func testStateConstants() {
        XCTAssertEqual(LXMPeerState.idle.rawValue,                 0x00)
        XCTAssertEqual(LXMPeerState.linkEstablishing.rawValue,     0x01)
        XCTAssertEqual(LXMPeerState.linkReady.rawValue,            0x02)
        XCTAssertEqual(LXMPeerState.requestSent.rawValue,          0x03)
        XCTAssertEqual(LXMPeerState.responseReceived.rawValue,     0x04)
        XCTAssertEqual(LXMPeerState.resourceTransferring.rawValue, 0x05)
    }

    func testErrorConstants() {
        XCTAssertEqual(LXMPeerError.noIdentity.rawValue,   0xF0)
        XCTAssertEqual(LXMPeerError.noAccess.rawValue,     0xF1)
        XCTAssertEqual(LXMPeerError.invalidKey.rawValue,   0xF3)
        XCTAssertEqual(LXMPeerError.invalidData.rawValue,  0xF4)
        XCTAssertEqual(LXMPeerError.invalidStamp.rawValue, 0xF5)
        XCTAssertEqual(LXMPeerError.throttled.rawValue,    0xF6)
        XCTAssertEqual(LXMPeerError.notFound.rawValue,     0xFD)
        XCTAssertEqual(LXMPeerError.timeout.rawValue,      0xFE)
    }

    func testSyncStrategyConstants() {
        XCTAssertEqual(LXMSyncStrategy.lazy.rawValue,       0x01)
        XCTAssertEqual(LXMSyncStrategy.persistent.rawValue, 0x02)
    }

    func testLXMPeerConstants() {
        XCTAssertEqual(LXMPeer.offerRequestPath,  "/offer")
        XCTAssertEqual(LXMPeer.messageGetPath,    "/get")
        XCTAssertEqual(LXMPeer.maxUnreachable,    14 * 24 * 60 * 60, accuracy: 0.01)
        XCTAssertEqual(LXMPeer.syncBackoffStep,   12 * 60,           accuracy: 0.01)
        XCTAssertEqual(LXMPeer.pathRequestGrace,  7.5,               accuracy: 0.01)
        XCTAssertEqual(LXMPeer.defaultSyncStrategy, .persistent)
    }

    // MARK: - Init defaults

    func testInitDefaults() {
        let router = makeRouter()
        let hash   = fakeHash()
        let peer   = LXMPeer(router: router, destinationHash: hash)

        XCTAssertEqual(peer.destinationHash, hash)
        XCTAssertEqual(peer.state,       .idle)
        XCTAssertFalse(peer.alive)
        XCTAssertEqual(peer.lastHeard,   0.0, accuracy: 0.001)
        XCTAssertEqual(peer.offered,     0)
        XCTAssertEqual(peer.outgoing,    0)
        XCTAssertEqual(peer.incoming,    0)
        XCTAssertEqual(peer.rxBytes,     0)
        XCTAssertEqual(peer.txBytes,     0)
        XCTAssertNil(peer.link)
        XCTAssertNil(peer.propagationStampCost)
        XCTAssertNil(peer.propagationTransferLimit)
        XCTAssertNil(peer.peeringCost)
        XCTAssertNil(peer.peeringKey)
        XCTAssertNil(peer.metadata)
        XCTAssertEqual(peer.lastOffer, [])
        XCTAssertNil(peer.currentlyTransferringMessages)
        XCTAssertEqual(peer.syncStrategy, .persistent)
    }

    // MARK: - Message tracking

    private func addFakeEntry(router: LXMRouter, tid: Data = Data(repeating: 0x01, count: 16)) {
        let destHash = Data(repeating: 0x02, count: 16)
        router.propagationEntries[tid] = PropagationEntry(
            destinationHash: destHash,
            filePath:        "/tmp/fake",
            received:        Date().timeIntervalSince1970,
            msgSize:         100,
            stampValue:      0
        )
    }

    func testAddHandledMessage() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addHandledMessage(tid)
        XCTAssertTrue(router.propagationEntries[tid]!.handledPeers.contains(peer.destinationHash))
    }

    func testAddHandledMessageIdempotent() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addHandledMessage(tid)
        peer.addHandledMessage(tid)  // second call must not duplicate
        XCTAssertEqual(router.propagationEntries[tid]!.handledPeers.count, 1)
    }

    func testAddUnhandledMessage() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addUnhandledMessage(tid)
        XCTAssertTrue(router.propagationEntries[tid]!.unhandledPeers.contains(peer.destinationHash))
    }

    func testRemoveHandledMessage() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addHandledMessage(tid)
        peer.removeHandledMessage(tid)
        XCTAssertFalse(router.propagationEntries[tid]!.handledPeers.contains(peer.destinationHash))
    }

    func testRemoveUnhandledMessage() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addUnhandledMessage(tid)
        peer.removeUnhandledMessage(tid)
        XCTAssertFalse(router.propagationEntries[tid]!.unhandledPeers.contains(peer.destinationHash))
    }

    func testHandledMessagesProperty() {
        let router = makeRouter()
        let tid1   = Data(repeating: 0x01, count: 16)
        let tid2   = Data(repeating: 0x02, count: 16)
        addFakeEntry(router: router, tid: tid1)
        addFakeEntry(router: router, tid: tid2)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addHandledMessage(tid1)

        let handled = peer.handledMessages
        XCTAssertTrue(handled.contains(tid1))
        XCTAssertFalse(handled.contains(tid2))
    }

    func testUnhandledMessagesProperty() {
        let router = makeRouter()
        let tid1   = Data(repeating: 0x01, count: 16)
        let tid2   = Data(repeating: 0x02, count: 16)
        addFakeEntry(router: router, tid: tid1)
        addFakeEntry(router: router, tid: tid2)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addUnhandledMessage(tid2)

        let unhandled = peer.unhandledMessages
        XCTAssertFalse(unhandled.contains(tid1))
        XCTAssertTrue(unhandled.contains(tid2))
    }

    func testHandledMessageCount() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addHandledMessage(tid)
        XCTAssertEqual(peer.handledMessageCount, 1)
    }

    func testUnhandledMessageCount() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addUnhandledMessage(tid)
        XCTAssertEqual(peer.unhandledMessageCount, 1)
    }

    func testAcceptanceRateZeroWhenOfferedZero() {
        let peer = LXMPeer(router: makeRouter(), destinationHash: fakeHash())
        XCTAssertEqual(peer.acceptanceRate, 0.0, accuracy: 0.001)
    }

    func testAcceptanceRate() {
        let peer    = LXMPeer(router: makeRouter(), destinationHash: fakeHash())
        peer.offered  = 10
        peer.outgoing = 7
        XCTAssertEqual(peer.acceptanceRate, 0.7, accuracy: 0.001)
    }

    // MARK: - Queuing

    func testQueueHandledThenProcess() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addUnhandledMessage(tid)

        peer.queueHandledMessage(tid)
        XCTAssertTrue(peer.hasQueuedItems)
        peer.processQueues()
        XCTAssertFalse(peer.hasQueuedItems)
        XCTAssertTrue(peer.handledMessages.contains(tid))
        XCTAssertFalse(peer.unhandledMessages.contains(tid))
    }

    func testQueueUnhandledThenProcess() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())

        peer.queueUnhandledMessage(tid)
        peer.processQueues()
        XCTAssertTrue(peer.unhandledMessages.contains(tid))
    }

    // MARK: - Serialization round-trip

    func testToBytesAndFromBytes() throws {
        let router = makeRouter()
        let hash   = fakeHash(0xBB)
        let peer   = LXMPeer(router: router, destinationHash: hash, syncStrategy: .lazy)
        peer.alive           = true
        peer.lastHeard       = 1_000_000.0
        peer.offered         = 5
        peer.outgoing        = 3
        peer.rxBytes         = 2048
        peer.txBytes         = 4096
        peer.peeringCost     = 10
        peer.propagationStampCost = 8

        let bytes  = peer.toBytes()
        let peer2  = try XCTUnwrap(LXMPeer.from(bytes: bytes, router: router))
        XCTAssertEqual(peer2.destinationHash, hash)
        XCTAssertEqual(peer2.syncStrategy,    .lazy)
        XCTAssertEqual(peer2.alive,           true)
        XCTAssertEqual(peer2.lastHeard,       1_000_000.0, accuracy: 0.001)
        XCTAssertEqual(peer2.offered,         5)
        XCTAssertEqual(peer2.outgoing,        3)
        XCTAssertEqual(peer2.rxBytes,         2048)
        XCTAssertEqual(peer2.txBytes,         4096)
        XCTAssertEqual(peer2.peeringCost,     10)
        XCTAssertEqual(peer2.propagationStampCost, 8)
    }

    func testFromBytesReturnsNilForGarbage() {
        let router = makeRouter()
        XCTAssertNil(LXMPeer.from(bytes: Data([0x01, 0x02, 0x03]), router: router))
    }

    func testSerializationPreservesHandledAndUnhandledIDs() {
        let router = makeRouter()
        let tid1   = Data(repeating: 0x01, count: 16)
        let tid2   = Data(repeating: 0x02, count: 16)
        addFakeEntry(router: router, tid: tid1)
        addFakeEntry(router: router, tid: tid2)

        let hash = fakeHash(0xCC)
        let peer = LXMPeer(router: router, destinationHash: hash)
        peer.addHandledMessage(tid1)
        peer.addUnhandledMessage(tid2)

        let bytes  = peer.toBytes()
        let peer2  = LXMPeer.from(bytes: bytes, router: router)
        XCTAssertNotNil(peer2)
        XCTAssertTrue(peer2!.handledMessages.contains(tid1))
        XCTAssertTrue(peer2!.unhandledMessages.contains(tid2))
    }

    // MARK: - processOfferResponse

    func testOfferResponseNoIdentity() {
        let peer   = LXMPeer(router: makeRouter(), destinationHash: fakeHash())
        let result = peer.processOfferResponse(.int(Int64(LXMPeerError.noIdentity.rawValue)))
        if case .error(let e) = result { XCTAssertEqual(e, .noIdentity) }
        else { XCTFail("Expected error(.noIdentity)") }
    }

    func testOfferResponseFalseNoneWanted() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addUnhandledMessage(tid)
        peer.lastOffer = [tid]

        let result = peer.processOfferResponse(.bool(false))
        if case .noneWanted = result {
            XCTAssertTrue(peer.handledMessages.contains(tid))
        } else { XCTFail("Expected noneWanted") }
    }

    func testOfferResponseTrueAllWanted() {
        let peer   = LXMPeer(router: makeRouter(), destinationHash: fakeHash())
        peer.lastOffer = [Data(repeating: 0x01, count: 16)]
        let result = peer.processOfferResponse(.bool(true))
        if case .allWanted = result { } else { XCTFail("Expected allWanted") }
    }

    func testOfferResponsePartialWanted() {
        let router = makeRouter()
        let tid1   = Data(repeating: 0x01, count: 16)
        let tid2   = Data(repeating: 0x02, count: 16)
        addFakeEntry(router: router, tid: tid1)
        addFakeEntry(router: router, tid: tid2)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addUnhandledMessage(tid1)
        peer.addUnhandledMessage(tid2)
        peer.lastOffer = [tid1, tid2]

        // Peer only wants tid2
        let response = MsgPack.Value.array([.bytes(tid2)])
        let result   = peer.processOfferResponse(response)
        if case .partialWanted(let ids) = result {
            XCTAssertEqual(ids, [tid2])
            // tid1 should now be marked as handled
            XCTAssertTrue(peer.handledMessages.contains(tid1))
        } else { XCTFail("Expected partialWanted") }
    }

    // MARK: - resourceConcluded

    func testResourceConcludedSuccess() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addUnhandledMessage(tid)
        peer.lastOffer = [tid]
        peer.currentlyTransferringMessages = [tid]
        peer.state = .resourceTransferring

        peer.resourceConcluded(success: true, dataSizeBytes: 512)
        XCTAssertTrue(peer.handledMessages.contains(tid))
        XCTAssertFalse(peer.unhandledMessages.contains(tid))
        XCTAssertEqual(peer.state,    .idle)
        XCTAssertNil(peer.link)
        XCTAssertNil(peer.currentlyTransferringMessages)
        XCTAssertTrue(peer.alive)
        XCTAssertEqual(peer.txBytes, 512)
    }

    func testResourceConcludedFailure() {
        let router = makeRouter()
        let tid    = Data(repeating: 0x01, count: 16)
        addFakeEntry(router: router, tid: tid)
        let peer   = LXMPeer(router: router, destinationHash: fakeHash())
        peer.addUnhandledMessage(tid)
        peer.currentlyTransferringMessages = [tid]
        peer.state  = .resourceTransferring
        peer.alive  = true

        peer.resourceConcluded(success: false, dataSizeBytes: 0)
        // Messages remain unhandled on failure
        XCTAssertTrue(peer.unhandledMessages.contains(tid))
        XCTAssertEqual(peer.state, .idle)
    }

    // MARK: - sync() guard paths

    func testSyncNoopsWhenNothingToSend() {
        let peer   = LXMPeer(router: makeRouter(), destinationHash: fakeHash())
        peer.propagationStampCost = 0
        peer.propagationStampCostFlexibility = 0
        peer.peeringCost = 0
        peer.peeringKey  = (stamp: Data(repeating: 0x00, count: 32), value: 0)
        // unhandledMessageCount == 0 → no state change
        peer.sync()
        XCTAssertEqual(peer.state, .idle)
    }

    func testSyncNoopsWhenStampCostsUnknown() {
        let peer   = LXMPeer(router: makeRouter(), destinationHash: fakeHash())
        // stamp costs nil → skip
        peer.sync()
        XCTAssertEqual(peer.state, .idle)
    }
}
