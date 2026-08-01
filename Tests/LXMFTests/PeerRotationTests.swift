import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/043` — rotation: dropping peers that do not accept what they are offered, to
/// keep headroom under the bound.
///
/// Python's `rotate_peers()` (`LXMRouter.py:2060-2130`) is one routine whose steps depend on each
/// other, and it is ported whole for that reason (design D4): headroom from `ROTATION_HEADROOM_PCT`,
/// a postponement while too many peers have never been tried, a preference for fully-synced peers
/// as the pool basis, an unresponsive/waiting split gated on `prioritiseRotatingUnreachablePeers`,
/// ordering by acceptance rate, and the `ROTATION_AR_MAX` floor.
///
/// Each test drives one step. Every one of them passes against a `rotatePeers()` that does nothing
/// **except** the first, so the falsification for the rest is against the implemented routine with
/// that step removed — recorded in the task notes rather than inferred.
final class PeerRotationTests: XCTestCase {

    /// Ten peers with a bound of ten: headroom is `max(1, floor(10 × 0.10))` = 1, so
    /// `required_drops` = 10 − (10 − 1) = **1**, and `10 − 1 > 1` holds. Exactly one peer goes,
    /// which is what makes "which one" assertable.
    private static let bound = 10

    private func makeRouter() -> LXMRouter {
        let router = LXMRouter(transport: Transport())
        router.maxPeers = Self.bound
        return router
    }

    private func hash(_ index: Int) -> Data {
        var bytes = Data(repeating: 0, count: LXMessage.destinationLength)
        bytes[0] = UInt8(index)
        return bytes
    }

    /// A peer that has been tried, is reachable and idle, and has been offered messages — the
    /// shape rotation considers. Anything a test wants different, it sets afterwards.
    @discardableResult
    private func addCandidate(_ router: LXMRouter, _ index: Int,
                              offered: Int = 10, outgoing: Int = 9) -> LXMPeer {
        router.peer(destinationHash: hash(index), timestamp: TimeInterval(1_000 + index),
                    transferLimit: 256, syncLimit: 256, stampCost: 0, stampCostFlexibility: 0,
                    peeringCost: 0, metadata: nil)
        let peer = router.peers[hash(index)]!
        peer.alive           = true
        peer.state           = .idle
        peer.lastSyncAttempt = 1_000          // tried, so it does not trigger the postponement
        peer.offered         = offered
        peer.outgoing        = outgoing
        return peer
    }

    /// A full table of good peers, plus whatever the caller makes of peer 0.
    private func fullTable(_ router: LXMRouter) {
        for index in 0..<Self.bound { addCandidate(router, index) }
    }

    // MARK: - The defect

    func testAPeerThatAcceptsNothingIsRotatedOut() {
        let router = makeRouter()
        fullTable(router)
        let refuser = router.peers[hash(0)]!
        refuser.outgoing = 0                  // offered 10, accepted none

        router.rotatePeers()

        XCTAssertNil(router.peers[hash(0)],
                     """
                     the peer has been offered \(refuser.offered) messages and accepted none, and \
                     the table is at its bound. Python drops it to recover headroom \
                     (LXMRouter.py:2116-2123); without rotation it holds a slot forever and is \
                     offered every message the node ever stores.
                     """)
        for index in 1..<Self.bound {
            XCTAssertNotNil(router.peers[hash(index)],
                            "peer \(index) accepts 90% of what it is offered and was dropped")
        }
    }

    // MARK: - The steps

    func testANewlyAddedPeerIsNotJudgedBeforeItHasBeenTried() {
        let router = makeRouter()
        fullTable(router)
        router.peers[hash(0)]!.outgoing = 0
        // Headroom is 1, so a single never-synced peer postpones the whole pass
        // (`LXMRouter.py:2072-2075`).
        router.peers[hash(1)]!.lastSyncAttempt = 0

        router.rotatePeers()

        XCTAssertEqual(router.peers.count, Self.bound,
                       """
                       rotation ran while \(1) peer had never been synced with. A peer that has \
                       just been added has no record to be judged on, and judging it drops \
                       whichever peer was added most recently rather than the worst one.
                       """)
    }

    func testAPeerThatHasBeenOfferedNothingIsNeverDropped() {
        let router = makeRouter()
        fullTable(router)
        // Offered nothing: its acceptance rate computes as 0, which would sort it first, but
        // Python excludes it from the candidates outright (`LXMRouter.py:2095-2098`).
        let untried = router.peers[hash(0)]!
        untried.offered  = 0
        untried.outgoing = 0
        // Someone must be droppable, or this passes for the wrong reason — and its acceptance
        // rate must be *above* zero. `acceptanceRate` returns 0.0 for a peer offered nothing, so a
        // droppable peer that also scores 0.0 ties with `untried`, and Swift's sort is not stable:
        // the outcome would depend on which of the two the tie-break happened to pick. Measured:
        // with both at 0.0 this test passed even with the exclusion removed.
        router.peers[hash(1)]!.outgoing = 1        // 10%, below the floor, and distinguishable

        router.rotatePeers()

        XCTAssertNotNil(router.peers[hash(0)],
                        """
                        a peer that has never been offered a message was dropped for having a 0% \
                        acceptance rate. It has no acceptance rate — it has no offers.
                        """)
        XCTAssertNil(router.peers[hash(1)], "the peer that actually refuses messages stayed")
    }

    func testNobodyIsDroppedWhenEveryCandidateIsAboveTheFloor() {
        let router = makeRouter()
        fullTable(router)
        // Worst peer accepts 60% — above ROTATION_AR_MAX (50%).
        router.peers[hash(0)]!.outgoing = 6

        router.rotatePeers()

        XCTAssertEqual(router.peers.count, Self.bound,
                       """
                       every peer accepts more than the \(Int(LXMRouter.rotationAcceptanceRateMax * 100))% \
                       floor, so the table stays over its threshold rather than dropping a \
                       perfectly good peer to satisfy the arithmetic (LXMRouter.py:2119-2123).
                       """)
    }

    func testAStaticPeerSurvivesRotation() {
        let router = makeRouter()
        fullTable(router)
        router.peers[hash(0)]!.outgoing = 0            // the worst peer by far
        router.setStaticPeers([hash(0)])
        router.peers[hash(1)]!.outgoing = 1            // the worst non-static peer

        router.rotatePeers()

        XCTAssertNotNil(router.peers[hash(0)],
                        """
                        a static peer is the operator's declared upstream, not a discovered one, \
                        and is exempt from rotation however badly it performs \
                        (LXMRouter.py:2092). Dropping it is not something discovery can repair.
                        """)
        XCTAssertNil(router.peers[hash(1)], "the worst non-static peer should have gone instead")
    }

    func testRotationDoesNothingBelowItsThreshold() {
        let router = makeRouter()
        for index in 0..<(Self.bound - 2) { addCandidate(router, index) }
        router.peers[hash(0)]!.outgoing = 0

        router.rotatePeers()

        XCTAssertEqual(router.peers.count, Self.bound - 2,
                       """
                       the table is below the point where headroom is needed, so rotation has \
                       nothing to recover (LXMRouter.py:2063). Rotation is not a quality filter \
                       that runs continuously; it runs when the table is nearly full.
                       """)
    }

    func testUnresponsivePeersAreDroppedBeforeReachableOnesWhenPrioritised() {
        let router = makeRouter()
        fullTable(router)
        router.prioritiseRotatingUnreachablePeers = true
        // The reachable peer with the worse record...
        router.peers[hash(0)]!.outgoing = 0
        // ...and an unreachable peer with a better one.
        let unreachable = router.peers[hash(1)]!
        unreachable.alive    = false
        unreachable.outgoing = 4

        router.rotatePeers()

        XCTAssertNil(router.peers[hash(1)],
                     """
                     with prioritise_rotating_unreachable_peers set, an unreachable peer is \
                     dropped ahead of a reachable one even though the reachable one has the worse \
                     acceptance rate (LXMRouter.py:2100-2106).
                     """)
        XCTAssertNotNil(router.peers[hash(0)], "the reachable peer was dropped instead")
    }

    func testAFullySyncedPeerIsPreferredAsTheRotationBasis() {
        let router = makeRouter()
        fullTable(router)
        // A peer with the worst record, but still holding messages it has not been given a chance
        // to take. Python narrows the pool to fully-synced peers when any exist (`:2075-2084`), so
        // this one is not considered on this pass.
        let stillSyncing = router.peers[hash(0)]!
        stillSyncing.outgoing = 0
        // The entry has to exist in the store first: `addUnhandledMessage` routes through the
        // router and is a no-op for a transient ID it does not hold, so calling it alone leaves
        // the peer looking fully synced and this test asserting nothing.
        let outstanding = Hashes.fullHash(Data("outstanding".utf8))
        router.seedPropagationEntry(outstanding, PropagationEntry(
            destinationHash: hash(200), filePath: "/tmp/none", received: 0, msgSize: 1,
            stampValue: 0))
        stillSyncing.addUnhandledMessage(outstanding)
        XCTAssertEqual(stillSyncing.unhandledMessageCount, 1,
                       "precondition: the peer must actually have something outstanding")
        // The worst of the fully-synced peers.
        router.peers[hash(1)]!.outgoing = 1

        router.rotatePeers()

        XCTAssertNotNil(router.peers[hash(0)],
                        """
                        a peer with messages still outstanding was judged on an acceptance rate \
                        that has not finished being measured. Python uses the fully-synced peers \
                        as the rotation basis when any exist (LXMRouter.py:2075-2084).
                        """)
        XCTAssertNil(router.peers[hash(1)], "the worst fully-synced peer should have gone")
    }
}
