import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/045` — a sync pass syncs **one** peer, chosen from a speed-weighted pool, and
/// culls peers unreachable past the maximum.
///
/// Python's `sync_peers()` (`LXMRouter.py:2131-2183`) does four things in order: cull non-static
/// peers not heard from for `MAX_UNREACHABLE`, keep only idle peers holding unhandled messages,
/// build a pool from the `FASTEST_N_RANDOM_POOL` fastest by `sync_transfer_rate` plus up to as many
/// again of unknown speed, and sync exactly one of them at random.
///
/// Swift's was `for peer in peerList { peer.sync() }` — four of the five steps missing. It is
/// latent only because the job loop never calls it (`bugs/019`); it becomes the node's real sync
/// behaviour as soon as that lands, which is why it is fixed in the same change rather than after.
final class PeerSyncSelectionTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_sync_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    /// Transports outlive the routers that hold them weakly; a deallocated one takes the
    /// propagation destination with it.
    private var retained: [Transport] = []

    private func makeNode() throws -> LXMRouter {
        let transport = Transport()
        retained.append(transport)
        let router = LXMRouter(transport: transport)
        try router.register(identity: Identity(), transport: transport)
        try router.enablePropagation(storagePath: tempDir + "/\(retained.count)")
        return router
    }

    private func hash(_ index: Int) -> Data {
        var bytes = Data(repeating: 0, count: LXMessage.destinationLength)
        bytes[0] = UInt8(index)
        return bytes
    }

    /// A peer that is due a sync: reachable, idle, past its backoff, and holding a message.
    @discardableResult
    private func addSyncablePeer(_ router: LXMRouter, _ index: Int,
                                 transferRate: Double = 0) -> LXMPeer {
        router.peer(destinationHash: hash(index), timestamp: TimeInterval(1_000 + index),
                    transferLimit: 256, syncLimit: 256, stampCost: 0, stampCostFlexibility: 0,
                    peeringCost: 0, metadata: nil)
        let peer = router.peers[hash(index)]!
        peer.alive            = true
        peer.state            = .idle
        peer.lastHeard        = Date().timeIntervalSince1970
        peer.nextSyncAttempt  = 0
        peer.syncTransferRate = transferRate
        // Stamp costs, so `sync()` gets past its first guard. No peering key is assigned: this
        // suite's observable is `lastSyncAttempt`, which `sync()` stamps unconditionally before
        // every gate (`LXMPeer.py:269`), so the key was never load-bearing here. Assigning one by
        // hand is also no longer possible, which is the point — see `swift_devel/bugs/054`.
        peer.propagationStampCost            = 0
        peer.propagationStampCostFlexibility = 0
        peer.peeringCost                     = 0
        peer.addUnhandledMessage(outstandingID)
        return peer
    }

    /// One message in the store, unhandled by every peer that asks for it.
    private lazy var outstandingID = Hashes.fullHash(Data("outstanding".utf8))

    private func seedStore(_ router: LXMRouter) {
        router.seedPropagationEntry(outstandingID, PropagationEntry(
            destinationHash: hash(250), filePath: "/tmp/none", received: 0, msgSize: 1,
            stampValue: 0))
    }

    /// Peers this pass **selected**, read from `lastSyncAttempt`, which `LXMPeer.sync()` stamps
    /// unconditionally before any of its own guards (`LXMPeer.swift:556-557`).
    ///
    /// Not `state != .idle`: `sync()` self-gates on backoff, outstanding messages and transfer
    /// state, so a peer the router *did* select can decline and stay `.idle`, making "not
    /// selected" and "selected, then declined" indistinguishable. Measured — with the state
    /// observable, removing the router's own outstanding-messages filter changed nothing any test
    /// could see. The router's selection is a separate property from the peer's decision, and the
    /// reference has both.
    private func syncsStarted(_ router: LXMRouter) -> [Data] {
        router.peers.values.filter { $0.lastSyncAttempt != 0 }.map(\.destinationHash)
    }

    // MARK: - The defect

    func testOneSyncStartsPerPass() throws {
        let router = try makeNode()
        seedStore(router)
        for index in 0..<5 { addSyncablePeer(router, index) }

        router.syncPeers()

        XCTAssertEqual(syncsStarted(router).count, 1,
                       """
                       five peers were due a sync and \(syncsStarted(router).count) were started \
                       in the same pass. Python starts one (LXMRouter.py:2172-2176); a full table \
                       means up to twenty concurrent link establishments and resource transfers on \
                       the constrained links propagation nodes sit behind.
                       """)
    }

    // MARK: - The cull

    func testAPeerUnreachablePastTheMaximumIsRemoved() throws {
        let router = try makeNode()
        seedStore(router)
        addSyncablePeer(router, 0)
        let gone = addSyncablePeer(router, 1)
        gone.lastHeard = Date().timeIntervalSince1970 - LXMPeer.maxUnreachable - 1

        router.syncPeers()

        XCTAssertNil(router.peers[hash(1)],
                     """
                     a peer not heard from for longer than MAX_UNREACHABLE stays in the table \
                     (LXMRouter.py:2138-2140, :2178-2183), so a peer that has gone away \
                     permanently is attempted on every pass for the life of the process.
                     """)
        XCTAssertNotNil(router.peers[hash(0)], "the reachable peer was culled too")
    }

    func testAStaticPeerIsNeverCulledForBeingUnreachable() throws {
        let router = try makeNode()
        seedStore(router)
        let upstream = addSyncablePeer(router, 0)
        upstream.lastHeard = Date().timeIntervalSince1970 - LXMPeer.maxUnreachable - 1
        router.staticPeers = [hash(0)]

        router.syncPeers()

        XCTAssertNotNil(router.peers[hash(0)],
                        """
                        a static peer is the operator's declared upstream; it is exempt from the \
                        unreachability cull (LXMRouter.py:2140) because a node behind a \
                        constrained link may legitimately be silent for a fortnight.
                        """)
    }

    // MARK: - Candidacy

    func testAPeerWithNothingOutstandingIsNotSynced() throws {
        let router = try makeNode()
        seedStore(router)
        let peer = addSyncablePeer(router, 0)
        peer.removeUnhandledMessage(outstandingID)

        router.syncPeers()

        XCTAssertTrue(syncsStarted(router).isEmpty,
                      """
                      a peer with no unhandled messages is not a sync candidate \
                      (LXMRouter.py:2142) — there is nothing to offer it.
                      """)
    }

    func testAPeerStillInSyncBackoffIsNotSynced() throws {
        let router = try makeNode()
        seedStore(router)
        let backing_off = addSyncablePeer(router, 0)
        backing_off.alive           = false
        backing_off.nextSyncAttempt = Date().timeIntervalSince1970 + 3_600

        router.syncPeers()

        XCTAssertTrue(syncsStarted(router).isEmpty,
                      """
                      an unresponsive peer inside its backoff window was retried anyway \
                      (LXMRouter.py:2145). Backoff exists so an unreachable peer is not dialled \
                      every pass.
                      """)
    }

    func testAReachablePeerIsPreferredOverAnUnresponsiveOne() throws {
        // Over many draws, not one: a single draw against a pool that wrongly included the
        // unresponsive peer would still pick the reachable one most of the time, so one pass
        // cannot tell "excluded" from "included and not drawn".
        var selected: Set<Data> = []
        for seed in 0..<32 {
            let router = try makeNode()
            seedStore(router)
            addSyncablePeer(router, 0)
            let unresponsive = addSyncablePeer(router, 1)
            unresponsive.alive = false

            var generator = SeededGenerator(seed: UInt64(seed))
            router.syncPeers(using: &generator)
            selected.formUnion(syncsStarted(router))
        }

        XCTAssertFalse(selected.contains(hash(1)),
                       """
                       an unresponsive peer was selected while a reachable one was waiting. \
                       Unresponsive peers are the pool only when nobody reachable is waiting \
                       (LXMRouter.py:2168-2170).
                       """)
        XCTAssertEqual(selected, [hash(0)], "the reachable peer should be the only one selected")
    }

    // MARK: - The pool

    func testTheFastestPeersFormThePool() throws {
        let router = try makeNode()
        seedStore(router)
        // Four peers of known speed. The pool is the two fastest (FASTEST_N_RANDOM_POOL), and
        // there are no unknown-speed peers to widen it, so the two slowest can never be selected.
        addSyncablePeer(router, 0, transferRate: 100)
        addSyncablePeer(router, 1, transferRate: 200)
        addSyncablePeer(router, 2, transferRate: 8_000)
        addSyncablePeer(router, 3, transferRate: 9_000)

        var selected: Set<Data> = []
        for seed in 0..<32 {
            let fresh = try makeNode()
            seedStore(fresh)
            addSyncablePeer(fresh, 0, transferRate: 100)
            addSyncablePeer(fresh, 1, transferRate: 200)
            addSyncablePeer(fresh, 2, transferRate: 8_000)
            addSyncablePeer(fresh, 3, transferRate: 9_000)
            var generator = SeededGenerator(seed: UInt64(seed))
            fresh.syncPeers(using: &generator)
            selected.formUnion(syncsStarted(fresh))
        }

        XCTAssertTrue(selected.isSubset(of: [hash(2), hash(3)]),
                      """
                      over 32 draws the selection reached \(selected.count) distinct peers, \
                      including one outside the two fastest. The pool is the \
                      \(LXMRouter.fastestNRandomPool) fastest by measured transfer rate \
                      (LXMRouter.py:2151-2155).
                      """)
        XCTAssertEqual(selected.count, 2,
                       "both of the two fastest should be reachable across 32 draws, not just one")
    }

    func testAnUntriedPeerCanBeSelectedAgainstAnEstablishedFastOne() throws {
        var selected: Set<Data> = []
        for seed in 0..<32 {
            let router = try makeNode()
            seedStore(router)
            // Two established fast peers, and two that have never been measured.
            addSyncablePeer(router, 0, transferRate: 8_000)
            addSyncablePeer(router, 1, transferRate: 9_000)
            addSyncablePeer(router, 2, transferRate: 0)
            addSyncablePeer(router, 3, transferRate: 0)

            var generator = SeededGenerator(seed: UInt64(seed))
            router.syncPeers(using: &generator)
            selected.formUnion(syncsStarted(router))
        }

        XCTAssertTrue(selected.contains(hash(2)) || selected.contains(hash(3)),
                      """
                      across 32 draws no peer of unknown speed was ever selected, so a node can \
                      never find out whether one is any good. Python widens the pool with up to as \
                      many unknown-speed peers as fast ones (LXMRouter.py:2157-2166) precisely so \
                      converging on good peers does not starve untried ones.
                      """)
        XCTAssertTrue(selected.contains(hash(0)) || selected.contains(hash(1)),
                      "the established fast peers were never selected either — the pool is not "
                      + "weighted, it is inverted")
    }
}

/// A deterministic `RandomNumberGenerator`, so the pool's *membership* can be asserted without
/// pinning production to a fixed choice (design D5). Selection stays genuinely random; a test that
/// pinned it would be testing the pin, and "always the fastest" is a different algorithm that
/// starves peers that have never been tried.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
