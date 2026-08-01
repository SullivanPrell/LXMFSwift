import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/054` — a propagation node pushes its store to its peers.
///
/// Every assertion here is about **B's message store**, not A's state machine. The defect these
/// replace was a machine that set `state = .linkEstablishing` and stopped; asserting A's state
/// cannot distinguish that from a working sync.
final class PeerOutboundSyncTests: XCTestCase {

    private var tempDir: String!
    private var net: PeerOutboundSyncNetwork!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_outsync_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        net = nil
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - The harness itself

    /// Not a test of the port — a test that the fixture below it means anything. If A never peers
    /// with B, every sync assertion in this file passes or fails for reasons unrelated to sync.
    func testTheHarnessPeersAWithBOverTheWire() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()

        XCTAssertEqual(peer.destinationHash, net.bPropagationHash)
        XCTAssertEqual(peer.peeringCost, 4,
                       "the announce must carry B's peering cost — without it A never builds a key")
        XCTAssertNotNil(peer.propagationStampCost, "and its stamp costs, or sync postpones forever")
        XCTAssertTrue(net.transportA.hasPath(to: net.bPropagationHash),
                      "the announce must also leave A with a path to dial")
        XCTAssertNotNil(net.transportA.recall(identity: net.bPropagationHash),
                        "and B's identity, or no peering material can be computed")
    }

    // MARK: - The peering key (design STEP 4)

    /// T4 — the defect stated directly: `peeringKey` had **no writer anywhere in `Sources/`**.
    func testSyncGeneratesThePeeringKeyWhenItIsMissing() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 2)
        let peer = try net.announceBToA()
        XCTAssertNil(peer.peeringKey, "precondition: no key yet")

        peer.sync()

        XCTAssertTrue(net.waitUntil("a peering key is generated", timeout: 10) {
            peer.peeringKey != nil
        }, """
        `sync()` postponed for want of a peering key and never started making one. Python spawns \
        the generation from exactly this branch (LXMPeer.py:283-286); without it \
        `peering_key_ready` is false forever and the peer never gets past its first guard — which \
        is why nothing downstream of it had a production caller.
        """)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(peer.peeringKeyValue), 2)
    }

    /// T3 — the generated key is checked by the **real inbound validator**, not by the generator's
    /// own idea of validity. Both halves live in this package; only a receiver can refute a key.
    func testAGeneratedKeyIsAcceptedByARealReceiver() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()

        XCTAssertTrue(peer.generatePeeringKey(), "generation must succeed at cost 4")
        let key = try XCTUnwrap(peer.peeringKey).stamp

        // B's own offer handler, reached the way a real offer reaches it.
        let answer = net.routerB.handleOfferRequest(
            data: .array([.bytes(key), .array([])]),
            remoteIdentityHash: net.identityA.hash,
            propagationHash: net.aPropagationHash,
            linkID: ObjectIdentifier(self))

        XCTAssertNotEqual(answer, .int(Int64(LXMPeerError.invalidKey.rawValue)),
                          """
                          the receiver refused a key this node generated for it. The material is \
                          receiver ‖ sender (LXMPeer.py:258 = LXMRouter.py:2300); swapping the \
                          halves, or using destination hashes instead of identity hashes, \
                          produces exactly this and is undiagnosable from the sender — its own \
                          validation of its own key succeeds.
                          """)
    }

    /// T5 — a peering cost of 0 is permanently unsatisfiable, not "free". Python's `if not
    /// self.peering_cost: return False` (`LXMPeer.py:228`) is a falsy test, and 0 is falsy.
    func testAPeeringCostOfZeroNeverBecomesReady() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        peer.peeringCost = 0

        peer.sync()
        net.settle(0.5)

        XCTAssertNil(peer.peeringKey,
                     """
                     a cost of 0 must not produce a key. `if not self.peering_cost` \
                     (LXMPeer.py:228) treats 0 as "no cost known", so the peering never becomes \
                     ready — the same behaviour Python-to-Python has, already documented at \
                     LXMRouter.swift:423-426 but never implemented.
                     """)
        XCTAssertEqual(peer.state, .idle)
    }

    /// T6 — a peer that raises its cost invalidates the key we hold for it.
    func testARaisedPeeringCostDiscardsAndRegeneratesTheKey() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 2)
        let peer = try net.announceBToA()

        XCTAssertTrue(peer.generatePeeringKey())
        let firstStamp = try XCTUnwrap(peer.peeringKey).stamp
        let firstValue = try XCTUnwrap(peer.peeringKeyValue)

        // The peer now demands more than the key we hold is worth.
        peer.peeringCost = firstValue + 3
        peer.sync()

        XCTAssertTrue(net.waitUntil("the key is regenerated", timeout: 20) {
            (peer.peeringKeyValue ?? -1) >= firstValue + 3
        }, """
        the stale key was kept. Python discards it — `self.peering_key = None` at \
        LXMPeer.py:233-234 — and the next pass regenerates. Keeping it means offering a key the \
        peer will refuse with ERROR_INVALID_KEY on every sync, forever.
        """)
        XCTAssertNotEqual(try XCTUnwrap(peer.peeringKey).stamp, firstStamp,
                          "a key worth more must be different bytes")
    }

    /// T20 — one generation, not one per caller. Python starts an unbounded daemon thread per
    /// postponed pass (`LXMPeer.py:285-286`), all serialising on a lock through a multi-second
    /// proof of work; at cost 18 the job loop can queue them faster than they retire.
    ///
    /// Driven through `generatePeeringKey()` directly, on eight threads. Going through `sync()`
    /// would prove nothing: `peeringKeyQueue` is serial, so it would single-flight the calls by
    /// itself and the gate under test would never be reached.
    func testConcurrentPeeringKeyGenerationStartsOneGeneration() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        // High enough that the first generation is still running when the others arrive.
        peer.peeringCost = 12

        let group = DispatchGroup()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) { peer.generatePeeringKey() }
        }
        group.wait()

        XCTAssertNotNil(peer.peeringKey, "precondition: one of them did the work")
        XCTAssertEqual(peer.peeringKeyGenerationsStarted, 1,
                       """
                       eight concurrent callers started \(peer.peeringKeyGenerationsStarted) key \
                       generations. Each is a full proof of work over a 6400-byte workblock, and \
                       they are redundant: all eight produce an equally valid key.
                       """)
    }

    /// The reference's own path — a postponing `sync()` is what starts generation — must go
    /// through the same gate, so a job loop firing every 24s cannot pile up proofs of work.
    func testRepeatedSyncPassesDoNotPileUpGenerations() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        peer.peeringCost = 10

        for _ in 0..<6 { peer.sync() }
        _ = net.waitUntil("generation finishes", timeout: 30) { peer.peeringKey != nil }
        net.settle(0.3)

        XCTAssertEqual(peer.peeringKeyGenerationsStarted, 1,
                       "six postponed passes must leave one generation behind, not six")
    }
}
