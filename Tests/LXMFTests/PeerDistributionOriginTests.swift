import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/049` and `/050` — a node does not offer a peer the messages that peer sent it.
///
/// Two separate omissions with one visible consequence.
///
/// **`bugs/049` — the distribution queue carries no origin.** Python queues
/// `[transient_id, from_peer]` and skips the originating peer when it fans out:
///
/// ```python
/// # LXMF/LXMRouter.py:2469-2486
/// def enqueue_peer_distribution(self, transient_id, from_peer):
///     self.peer_distribution_queue.append([transient_id, from_peer])
/// ...
///         if peer != from_peer:
///             peer.queue_unhandled_message(transient_id)
/// ```
///
/// Swift's queue is `[Data]` — transient IDs only — so every peer gets every message, including
/// the one that just uploaded it. Python also marks the message *handled* for the sender at the
/// ingest site (`:2445`, `peer.queue_handled_message(transient_id)`), which this port omits.
///
/// **`bugs/050` — `addPeer` back-fills the whole store.** Python's `peer()` constructs a peer and
/// sets its advertised terms and nothing else (`:2032-2045`); `unhandled_messages` is a *derived*
/// property over `propagation_entries` (`LXMPeer.py:583-588`), so a brand-new peer has none.
/// Seeding happens only in `from_bytes` (`:118-129`), restoring sets that were previously
/// recorded. Swift's `addPeer` marks every message in the store unhandled for a peer the instant
/// it is created.
///
/// Together, on a real mesh: an unpeered Python node syncs one message to a Swift node holding
/// 5,000. The Swift node ingests it, autopeers, seeds all 5,001 as unhandled for that peer, and
/// its next sync offers the peer its own message back along with the entire store. Python-to-Python
/// the same event produces an empty offer.
final class PeerDistributionOriginTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_distorigin_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        retained.removeAll()
        super.tearDown()
    }

    // MARK: - bugs/049 — the origin exclusion

    func testAMessageIsNotOfferedBackToThePeerThatSentIt() throws {
        let router = try makeNode()
        let sender = try addPeer(to: router, tag: 0xA1)
        let other  = try addPeer(to: router, tag: 0xB2)

        let tid = try store(oneMessageIn: router, from: sender)
        router.flushPeerDistributionQueue()

        XCTAssertFalse(sender.unhandledMessages.contains(tid),
                       """
                       the message this peer just uploaded was queued straight back to it \
                       (LXMRouter.py:2484, `if peer != from_peer`). The peer already has it — \
                       offering it back costs an offer round trip every sync, and on a two-node \
                       mesh the two nodes offer each other the same message forever.
                       """)
        XCTAssertTrue(other.unhandledMessages.contains(tid),
                      """
                      every *other* peer must still receive it — an exclusion that dropped the \
                      message for everyone would stop the ping-pong by stopping propagation.
                      """)
    }

    func testTheFanOutSkipsTheOriginOnItsOwn() throws {
        let router = try makeNode()
        let sender = try addPeer(to: router, tag: 0xA1)
        let other  = try addPeer(to: router, tag: 0xB2)

        // Stored WITHOUT going through `ingestPropagatedLXM`, so the sender is not also marked
        // handled. Both mechanisms exist in the reference — `queue_handled_message` at
        // LXMRouter.py:2445 and `if peer != from_peer` at :2484 — and with ingest driving the test
        // the handled-marking alone satisfies it, leaving the exclusion unfalsifiable. This drives
        // the queue directly so the exclusion is the only thing that can hold.
        let tid = try storeWithoutDistributing(in: router)
        router.enqueueForPeerDistribution(transientID: tid, fromPeer: sender)
        router.flushPeerDistributionQueue()

        XCTAssertFalse(sender.unhandledMessages.contains(tid),
                       "the fan-out must skip the originating peer (LXMRouter.py:2484)")
        XCTAssertTrue(other.unhandledMessages.contains(tid),
                      "and must reach every other peer")
    }

    func testAMessageFromNoPeerReachesEveryPeer() throws {
        let router = try makeNode()
        let a = try addPeer(to: router, tag: 0xA1)
        let b = try addPeer(to: router, tag: 0xB2)

        // A client upload, not a peer sync: `from_peer` is nil and nobody is excluded.
        let tid = try store(oneMessageIn: router, from: nil)
        router.flushPeerDistributionQueue()

        XCTAssertTrue(a.unhandledMessages.contains(tid), "peer A must be offered a client upload")
        XCTAssertTrue(b.unhandledMessages.contains(tid), "peer B must be offered a client upload")
    }

    func testTheSendingPeerIsMarkedAsAlreadyHavingIt() throws {
        let router = try makeNode()
        let sender = try addPeer(to: router, tag: 0xA1)

        let tid = try store(oneMessageIn: router, from: sender)
        router.flushPeerDistributionQueue()

        XCTAssertTrue(sender.handledMessages.contains(tid),
                      """
                      Python records the message as handled for the peer that supplied it \
                      (LXMRouter.py:2445, queue_handled_message). Without that the node knows only \
                      that it must not offer it now — after a restart, or once the entry is \
                      rebuilt, it has no record that the peer already had it.
                      """)
    }

    // MARK: - bugs/050 — a new peer starts empty

    func testANewPeerIsNotOfferedTheExistingStore() throws {
        let router = try makeNode()
        _ = try store(oneMessageIn: router, from: nil)
        _ = try store(oneMessageIn: router, from: nil)
        XCTAssertEqual(router.propagationEntries.count, 2, "precondition: the store is not empty")

        let fresh = try addPeer(to: router, tag: 0xC3)

        XCTAssertEqual(fresh.unhandledMessageCount, 0,
                       """
                       a peer created now was handed the node's entire existing store \
                       (\(router.propagationEntries.count) messages) as unhandled. Python's peer() \
                       seeds nothing (LXMRouter.py:2032-2045) — unhandled_messages is derived from \
                       the store's per-entry peer lists (LXMPeer.py:583-588), so a new peer has \
                       none, and it receives only what arrives after peering.
                       """)
    }

    func testARestoredPeerKeepsTheSetsItWasSavedWith() throws {
        let router = try makeNode()
        let peer = try addPeer(to: router, tag: 0xD4)
        let tid = try store(oneMessageIn: router, from: nil)
        router.flushPeerDistributionQueue()
        XCTAssertTrue(peer.unhandledMessages.contains(tid), "precondition: the peer was offered it")

        // Round-trip through the serialised form, as a restart does.
        let restored = try XCTUnwrap(LXMPeer.from(bytes: peer.toBytes(), router: router),
                                     "the peer must survive serialisation")

        XCTAssertTrue(restored.unhandledMessages.contains(tid),
                      """
                      the seeding that `addPeer` must not do is exactly what restore must: Python \
                      re-adds the saved handled/unhandled IDs in `from_bytes` \
                      (LXMPeer.py:118-129). Removing the back-fill from peer creation must not \
                      take restore with it.
                      """)
    }

    // MARK: - Harness

    private var retained: [AnyObject] = []

    private func makeNode() throws -> LXMRouter {
        let transport = Transport()
        retained.append(transport)
        let router = LXMRouter(transport: transport)
        router.propagationStampCost = 0
        try router.register(identity: Identity(), transport: transport)
        try router.enablePropagation(storagePath: tempDir)
        retained.append(router)
        return router
    }

    private func addPeer(to router: LXMRouter, tag: UInt8) throws -> LXMPeer {
        let hash = Data(repeating: tag, count: 16)
        router.peer(destinationHash: hash, timestamp: Date().timeIntervalSince1970,
                    transferLimit: nil, syncLimit: nil, stampCost: 0,
                    stampCostFlexibility: 0, peeringCost: 0, metadata: nil)
        return try XCTUnwrap(router.peers[hash], "the peer was not created")
    }

    /// Store one message directly, bypassing the distribution enqueue and the handled-marking.
    private func storeWithoutDistributing(in router: LXMRouter) throws -> Data {
        let source = try Destination(identity: Identity(), direction: .in, kind: .single,
                                     appName: APP_NAME, aspects: ["delivery"])
        let destination = try Destination(identity: Identity(), direction: .in, kind: .single,
                                          appName: APP_NAME, aspects: ["delivery"])
        let message = LXMessage(destination: destination, source: source,
                                content: "direct \(UUID().uuidString)")
        try message.pack()
        let lxmfData = try XCTUnwrap(message.packed)
        let tid = Hashes.fullHash(lxmfData)
        _ = router.addToMessageStore(lxmfData: lxmfData, transientID: tid, stampValue: 0,
                                     stamp: Data(repeating: 0, count: 32))
        return tid
    }

    /// Store one message, attributed to `origin` (nil = a client upload).
    @discardableResult
    private func store(oneMessageIn router: LXMRouter, from origin: LXMPeer?) throws -> Data {
        let source = try Destination(identity: Identity(), direction: .in, kind: .single,
                                     appName: APP_NAME, aspects: ["delivery"])
        let destination = try Destination(identity: Identity(), direction: .in, kind: .single,
                                          appName: APP_NAME, aspects: ["delivery"])
        let message = LXMessage(destination: destination, source: source,
                                content: "distribute \(UUID().uuidString)")
        try message.pack()
        let lxmfData = try XCTUnwrap(message.packed)
        _ = router.ingestPropagatedLXM(lxmfData: lxmfData, stampValue: 0, stamp: Data(repeating: 0, count: 32),
                                       fromPeer: origin)
        return Hashes.fullHash(lxmfData)
    }
}
