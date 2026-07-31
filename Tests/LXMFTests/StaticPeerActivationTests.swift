import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/051` — a configured static peering actually happens, and survives a restart.
///
/// Python activates static peers at the end of `enable_propagation` (`LXMRouter.py:633-641`): any
/// static peer that was not restored from disk gets an entry, and one that has never been heard
/// from gets a path request — a peer that was offline at startup will not announce on its own, so
/// the solicited path response is the only way its advertised terms are ever learned.
///
/// The port had `staticPeers` as a set that rotation and sync selection filtered against, and no
/// code path that ever put a peer into the table because of it. An operator could configure a
/// peering and get nothing: no entry, no path request, no error.
///
/// `swift_devel/bugs/052` — and the table is written back, not only read. Python persists on exit
/// via atexit and the SIGINT/SIGTERM handlers (`:307-309`, `:1400-1423`). This port had a fully
/// implemented reader for a file no production path produced, because `savePeers` was reachable
/// only from `disablePropagation`, which nothing calls.
final class StaticPeerActivationTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_staticpeer_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        retained.removeAll()
        super.tearDown()
    }

    // MARK: - Activation

    func testAConfiguredStaticPeerIsInTheTableOncePropagationStarts() throws {
        let hash = Data(repeating: 0x51, count: 16)
        let router = try makeNode(staticPeers: [hash])

        XCTAssertNotNil(router.peers[hash],
                        """
                        a static peering was configured and no peer was created \
                        (LXMRouter.py:633-641). `staticPeers` was a set the sync and rotation \
                        paths filtered against and nothing ever added to, so the operator's \
                        configuration had no effect and produced no error.
                        """)
    }

    func testEachConfiguredStaticPeerGetsItsOwnEntry() throws {
        let a = Data(repeating: 0x51, count: 16)
        let b = Data(repeating: 0x52, count: 16)
        let router = try makeNode(staticPeers: [a, b])

        XCTAssertNotNil(router.peers[a], "the first static peer")
        XCTAssertNotNil(router.peers[b], "the second static peer")
        XCTAssertEqual(router.peers.count, 2, "and nothing else")
    }

    func testStartingWithNoStaticPeersCreatesNoPeers() throws {
        let router = try makeNode(staticPeers: [])

        XCTAssertTrue(router.peers.isEmpty,
                      "activation must create peers for configured hashes only")
    }

    func testAStaticPeerThatWasRestoredIsNotDuplicated() throws {
        let hash = Data(repeating: 0x51, count: 16)

        let first = try makeNode(staticPeers: [hash])
        let peer = try XCTUnwrap(first.peers[hash])
        peer.lastHeard = Date().timeIntervalSince1970
        peer.propagationStampCost = 7
        first.savePeers()

        // Same storage, new router: the peer comes back from disk and activation must leave it be.
        let second = try makeNode(staticPeers: [hash])

        XCTAssertEqual(second.peers.count, 1, "the restored peer must not be joined by a fresh one")
        XCTAssertEqual(second.peers[hash]?.propagationStampCost, 7,
                       """
                       activation replaced a restored static peer with a blank one, discarding the \
                       terms and sync history it was saved with. Python creates an entry only \
                       `if not static_peer in self.peers` (LXMRouter.py:635).
                       """)
    }

    // MARK: - Persistence

    func testThePeerTableIsWrittenBackByTheJobLoop() throws {
        let hash = Data(repeating: 0x53, count: 16)
        let router = try makeNode(staticPeers: [])
        router.peer(destinationHash: hash, timestamp: Date().timeIntervalSince1970,
                    transferLimit: nil, syncLimit: nil, stampCost: 5,
                    stampCostFlexibility: 0, peeringCost: 0, metadata: nil)
        XCTAssertNotNil(router.peers[hash], "precondition: the peer exists")

        // Run the loop far enough for the save job to come round.
        for _ in 1...LXMRouter.jobSaveInterval { _ = router.jobs() }

        let peersFile = tempDir + "/lxmf/peers"
        XCTAssertTrue(FileManager.default.fileExists(atPath: peersFile),
                      """
                      the peer table was never written. `enablePropagation` reads \
                      `<storage>/lxmf/peers` at startup, so the port had a complete reader for a \
                      file nothing produced: `savePeers` was reachable only from \
                      `disablePropagation`, which has no caller. What is lost is not just the peer \
                      list — it is every peer's handled/unhandled sets, its peering timebase and \
                      its measured transfer rate.
                      """)

        let restored = try makeNode(staticPeers: [])
        XCTAssertEqual(restored.peers[hash]?.propagationStampCost, 5,
                       "and what was written must come back")
    }

    func testTheSaveJobDeclaresWhyItDivergesFromTheReference() throws {
        let job = try XCTUnwrap(LXMRouter.jobSchedule.first { $0.name == "savePeers" })
        XCTAssertNotNil(job.additionReason,
                        """
                        the reference persists on exit only, so a scheduled save is a deliberate \
                        divergence — this port's primary consumer is an iOS app, which is \
                        terminated without notice and cannot run an exit handler. It must say so \
                        in the schedule, where the comparison against LXMRouter.py:880-911 lives.
                        """)
    }

    // MARK: - Harness

    private var retained: [AnyObject] = []

    private func makeNode(staticPeers: [Data]) throws -> LXMRouter {
        let transport = Transport()
        retained.append(transport)
        let router = LXMRouter(transport: transport)
        router.propagationStampCost = 0
        router.staticPeers = Set(staticPeers)
        try router.register(identity: Identity(), transport: transport)
        try router.enablePropagation(storagePath: tempDir)
        retained.append(router)
        return router
    }
}
