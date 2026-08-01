import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/043` — the peer table has a ceiling and a guarded way out.
///
/// Python bounds the table at `MAX_PEERS = 20` (`LXMRouter.py:43`) and enforces it inside `peer()`
/// (`:2032`), the single point every peering passes through, so no caller can peer around it. It
/// removes peers through `unpeer()` (`:2049-2057`), which is guarded by the peering timebase and
/// is the removal path used by rotation (`:2122`), by the peering-cost ceiling (`:2008`) and by the
/// remote control verb `peer_unpeer_request` (`:864`).
///
/// The cost of an unbounded table is not one dictionary entry per peer: each peer carries an
/// unhandled-message set spanning the whole store, so it is one queue per peer.
final class PeerTableBoundTests: XCTestCase {

    private func makeRouter() -> LXMRouter { LXMRouter(transport: Transport()) }

    private func hash(_ index: Int) -> Data {
        var bytes = Data(repeating: 0, count: LXMessage.destinationLength)
        bytes[0] = UInt8(index % 256)
        bytes[1] = UInt8(index / 256)
        return bytes
    }

    /// Peer through the same entry point production uses, at a timebase that always advances.
    private func peer(_ router: LXMRouter, _ index: Int, peeringCost: Int = 0) {
        router.peer(destinationHash: hash(index), timestamp: TimeInterval(1_000 + index),
                    transferLimit: 256, syncLimit: 256, stampCost: 0, stampCostFlexibility: 0,
                    peeringCost: peeringCost, metadata: nil)
    }

    // MARK: - The bound

    func testPeeringStopsAtTheBound() {
        let router = makeRouter()
        for index in 0..<router.maxPeers { peer(router, index) }
        XCTAssertEqual(router.peers.count, router.maxPeers, "precondition: the table is full")

        peer(router, router.maxPeers)

        XCTAssertEqual(router.peers.count, router.maxPeers,
                       """
                       the table was already at its maximum of \(router.maxPeers) and grew to \
                       \(router.peers.count) (LXMRouter.py:2032). Every peer carries an \
                       unhandled-message set over the whole store, so an unbounded table is an \
                       unbounded number of queues.
                       """)
        XCTAssertNil(router.peers[hash(router.maxPeers)], "the peer past the bound was admitted")
    }

    func testAnExistingPeerIsStillUpdatedWhenTheTableIsFull() throws {
        let router = makeRouter()
        for index in 0..<router.maxPeers { peer(router, index) }

        router.peer(destinationHash: hash(0), timestamp: 9_999, transferLimit: 512, syncLimit: 512,
                    stampCost: 7, stampCostFlexibility: 0, peeringCost: 0, metadata: nil)

        let existing = try XCTUnwrap(router.peers[hash(0)])
        XCTAssertEqual(existing.propagationStampCost, 7,
                       """
                       the bound applies to admitting a *new* peer (LXMRouter.py:2031-2032). An \
                       existing peer that re-peers must still have its negotiated limits updated, \
                       or a full node stops tracking what its peers will accept.
                       """)
    }

    func testTheBoundIsConfigurable() {
        let router = makeRouter()
        router.setMaxPeers(3)
        for index in 0..<10 { peer(router, index) }

        XCTAssertEqual(router.peers.count, 3,
                       "maxPeers is a per-node setting (LXMRouter.py:206), not a constant")
    }

    func testTheDefaultBoundMatchesTheReference() {
        XCTAssertEqual(makeRouter().maxPeers, 20, "Python: LXMRouter.MAX_PEERS = 20 (:43)")
    }

    // MARK: - The peering-cost ceiling

    func testANodeDemandingMoreThanTheCeilingIsNotPeeredWith() {
        let router = makeRouter()
        peer(router, 1, peeringCost: router.maxPeeringCost + 1)

        XCTAssertNil(router.peers[hash(1)],
                     """
                     the remote demands a peering cost above this node's ceiling of \
                     \(router.maxPeeringCost) (LXMRouter.py:2005-2010). Peering anyway commits the \
                     node to generating a peering key it decided was too expensive.
                     """)
    }

    func testAPeerThatRaisesItsCostBeyondTheCeilingIsDropped() {
        let router = makeRouter()
        peer(router, 1, peeringCost: 0)
        XCTAssertNotNil(router.peers[hash(1)], "precondition: peered at an acceptable cost")

        peer(router, 1, peeringCost: router.maxPeeringCost + 1)

        XCTAssertNil(router.peers[hash(1)],
                     """
                     an existing peer that raises its peering cost beyond the ceiling must have \
                     the peering broken, not merely be refused a fresh one (LXMRouter.py:2006-2008).
                     """)
    }

    // MARK: - Unpeering

    func testAStaleUnpeerDoesNotRemoveARepeeredPeer() {
        let router = makeRouter()
        router.peer(destinationHash: hash(1), timestamp: 2_000, transferLimit: 256, syncLimit: 256,
                    stampCost: 0, stampCostFlexibility: 0, peeringCost: 0, metadata: nil)

        router.unpeer(destinationHash: hash(1), timestamp: 1_000)

        XCTAssertNotNil(router.peers[hash(1)],
                        """
                        an unpeer older than the peer's current peering timebase must be ignored \
                        (LXMRouter.py:2054). Announces reorder in a mesh; without the guard a \
                        delayed unpeer removes a peer that has since re-peered.
                        """)
    }

    func testACurrentUnpeerRemovesThePeer() {
        let router = makeRouter()
        router.peer(destinationHash: hash(1), timestamp: 2_000, transferLimit: 256, syncLimit: 256,
                    stampCost: 0, stampCostFlexibility: 0, peeringCost: 0, metadata: nil)

        router.unpeer(destinationHash: hash(1), timestamp: 2_000)

        XCTAssertNil(router.peers[hash(1)],
                     "an unpeer at the peer's own timebase removes it (LXMRouter.py:2054 is >=)")
    }

    func testUnpeeringClearsThePeersReferencesFromTheMessageStore() throws {
        let router = makeRouter()
        let storage = NSTemporaryDirectory() + "lxmf_bound_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: storage) }
        try router.enablePropagation(storagePath: storage)

        router.peer(destinationHash: hash(1), timestamp: 2_000, transferLimit: 256, syncLimit: 256,
                    stampCost: 0, stampCostFlexibility: 0, peeringCost: 0, metadata: nil)
        let transientID = Hashes.fullHash(Data("held".utf8))
        router.seedPropagationEntry(transientID, PropagationEntry(
            destinationHash: hash(9), filePath: "/tmp/none", received: 0, msgSize: 1,
            unhandledPeers: [hash(1)], stampValue: 0))

        router.unpeer(destinationHash: hash(1), timestamp: 3_000)

        let entry = try XCTUnwrap(router.propagationEntries[transientID])
        XCTAssertFalse(entry.unhandledPeers.contains(hash(1)),
                       """
                       the store still lists a peer that no longer exists. Swift keeps the \
                       unhandled/handled peer lists on the entry where Python derives them, so \
                       dropping a peer has to clear them or every entry accumulates dead hashes.
                       """)
    }
}
