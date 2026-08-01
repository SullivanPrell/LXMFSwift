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

    // MARK: - The sync itself (design STEPS 5-8)

    /// T1 — **the defect test.** A message stored on A reaches B's store.
    ///
    /// Everything else in this file is a detail of how; this is the thing that did not happen.
    func testSyncDeliversAStoredMessageToThePeerNode() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())

        let tid = try net.storeMessage(in: net.routerA, size: 400)
        XCTAssertTrue(peer.unhandledMessages.contains(tid), "precondition: B is owed this message")

        net.routerA.syncPeers()

        XCTAssertTrue(net.waitUntil("the message reaches B") {
            net.routerB.propagationEntries[tid] != nil
        }, """
        the message never arrived. `LXMPeer.sync()` set `state = .linkEstablishing` and returned \
        without opening a Link — a node built on this port could accept syncs and serve clients, \
        but between two Swift nodes nothing ever moved.
        """)

        XCTAssertTrue(peer.handledMessages.contains(tid), "and A must record that B now has it")
        XCTAssertFalse(peer.unhandledMessages.contains(tid))
        XCTAssertEqual(peer.outgoing, 1)
        XCTAssertEqual(peer.offered, 1)
        XCTAssertEqual(peer.state, .idle, "and the peer must be ready for the next pass")
    }

    /// T0 — **the ordering invariant.** Over this synchronous wire the whole machine runs inside
    /// `Link.initiate`; a state write after any callout stomps a later transition, and `syncPeers`
    /// only ever selects `.idle`, so the peer is then ineligible forever.
    func testTheSyncCommitsItsStateBeforeEveryCallout() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())

        let first = try net.storeMessage(in: net.routerA, size: 400)
        net.routerA.syncPeers()
        XCTAssertTrue(net.waitUntil("first message lands") {
            net.routerB.propagationEntries[first] != nil
        }, "precondition: the first sync works")

        XCTAssertEqual(peer.state, .idle,
                       """
                       a state write landed after a callout and stomped a later transition. \
                       `syncPeers` selects only `state == .idle` (LXMRouter.swift:3038), so this \
                       peer would never be chosen again.
                       """)
        XCTAssertNil(peer.linkForTesting, "and the link must be released, not left dangling")

        // The proof that it is not wedged: a second pass must work too.
        let second = try net.storeMessage(in: net.routerA, size: 400)
        net.routerA.syncPeers()
        XCTAssertTrue(net.waitUntil("second message lands") {
            net.routerB.propagationEntries[second] != nil
        }, "the peer was left wedged after the first sync — one message, then silence forever")
    }

    /// T7 — without identifying, B answers `ERROR_NO_IDENTITY` and nothing transfers.
    func testTheSyncLinkIdentifiesToThePeerNode() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())

        var identifiedAs: Data?
        net.routerB.propagationDestination?.onLinkEstablished = { link in
            link.onRemoteIdentified = { _, identity in identifiedAs = identity.hash }
        }

        _ = try net.storeMessage(in: net.routerA, size: 400)
        net.routerA.syncPeers()
        _ = net.waitUntil("B sees an identity") { identifiedAs != nil }

        XCTAssertEqual(identifiedAs, net.identityA.hash,
                       """
                       the sync link never identified. B keys both the peering-key check and the \
                       throttle off the remote identity (LXMRouter.swift:3110); an unidentified \
                       link is answered with ERROR_NO_IDENTITY and no message ever moves.
                       """)
    }

    /// T18 — a peer with no path gets a path request, and **does not** burn sync backoff for it.
    /// Python bumps the backoff at `:321`, after the path gate, not before.
    func testAMissingPathRequestsOneWithoutBurningBackoff() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())
        _ = try net.storeMessage(in: net.routerA, size: 400)

        // Drop the path A learned from the announce, so the gate is the only thing it can hit.
        _ = net.transportA.dropPath(for: net.bPropagationHash)
        XCTAssertFalse(net.transportA.hasPath(to: net.bPropagationHash), "precondition")
        net.interfaceA.clearSent()

        peer.sync()
        net.settle(0.3)

        XCTAssertFalse(net.interfaceA.sentPathRequests().isEmpty,
                       "a peer with no path must be asked for one (LXMPeer.py:295-297)")
        XCTAssertEqual(peer.syncBackoff, 0,
                       """
                       waiting for a path is not a failed sync. Python bumps the backoff at \
                       LXMPeer.py:321 — *after* the path gate — so a node that is merely waiting \
                       for a path answer is not pushed into a 12-minute penalty for it.
                       """)
        XCTAssertEqual(peer.nextSyncAttempt, 0)
    }

    // MARK: - The offer (design STEP 6)

    /// T2 — the offer payload is `[peeringKeyStamp, [transientID…]]`, in that order.
    func testTheOfferCarriesThePeeringKeyThenTheTransientIDs() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())
        let expectedKey = try XCTUnwrap(peer.peeringKey).stamp

        var captured: MsgPack.Value?
        net.routerB.propagationDestination?.registerNativeRequestHandler(
            path: LXMPeer.offerRequestPath, allow: .all
        ) { _, value, _, _, _ in
            captured = value
            return .bool(false)          // "I have everything" — ends the sync cleanly
        }

        let tid = try net.storeMessage(in: net.routerA, size: 400)
        net.routerA.syncPeers()
        _ = net.waitUntil("the offer arrives") { captured != nil }

        guard case .array(let elements)? = captured, elements.count == 2 else {
            return XCTFail("the offer must be a two-element array (LXMPeer.py:385), got \(captured as Any)")
        }
        guard case .bytes(let key) = elements[0] else {
            return XCTFail("element 0 must be the raw 32-byte peering stamp, got \(elements[0])")
        }
        XCTAssertEqual(Data(key), expectedKey,
                       "the raw stamp travels — never the value integer alongside it")
        XCTAssertEqual(elements[1], .array([.bytes(tid)]),
                       "element 1 is the transient-ID list")
    }

    /// The offer order is Python's weight, not receive time. `get_weight` is
    /// `priority * age * size` (`LXMRouter.py:1056-1067`); this port returned `received`.
    func testTheOfferIsOrderedByWeightNotReceiveTime() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())

        // Stored oldest-first, but with sizes that invert the weight order.
        let big   = try net.storeMessage(in: net.routerA, size: 4_000)
        let small = try net.storeMessage(in: net.routerA, size: 200)

        var captured: MsgPack.Value?
        net.routerB.propagationDestination?.registerNativeRequestHandler(
            path: LXMPeer.offerRequestPath, allow: .all
        ) { _, value, _, _, _ in captured = value; return .bool(false) }

        net.routerA.syncPeers()
        _ = net.waitUntil("the offer arrives") { captured != nil }

        guard case .array(let elements)? = captured, case .array(let ids) = elements[1] else {
            return XCTFail("no offer captured")
        }
        let order = ids.compactMap { v -> Data? in
            if case .bytes(let b) = v { return Data(b) } else { return nil }
        }
        XCTAssertEqual(order, [small, big],
                       """
                       offers go out lightest-first by `priorityWeight * ageWeight * size`. \
                       Sorting on `received` instead — which is what `getWeight` returned — puts \
                       a 4 KB message ahead of a 200-byte one purely because it was stored first, \
                       so a per-sync limit spends its budget on the wrong messages.
                       """)
    }

    // MARK: - Offer responses (design STEP 7)

    /// T9 — `ERROR_THROTTLED` postpones by `PN_STAMP_THROTTLE`.
    func testAThrottledResponsePostponesTheNextSync() throws {
        let peer = try syncAgainst(response: .uint(UInt64(LXMPeerError.throttled.rawValue)))

        let delay = peer.nextSyncAttempt - Date().timeIntervalSince1970
        XCTAssertEqual(delay, LXMRouter.pnStampThrottle, accuracy: 3.0,
                       """
                       the peer said it is throttling us and the sync was not postponed \
                       (LXMPeer.py:421-425). Retrying at the normal cadence into a node that is \
                       refusing us is what the throttle exists to stop.
                       """)
    }

    /// T10 — `ERROR_NO_ACCESS` breaks the peering.
    func testANoAccessResponseBreaksThePeering() throws {
        let peer = try syncAgainst(response: .uint(UInt64(LXMPeerError.noAccess.rawValue)))

        XCTAssertNil(net.routerA.peers[peer.destinationHash],
                     """
                     the peer told us we are not welcome and we kept it in the table \
                     (LXMPeer.py:416-419), so we go on dialling it every pass forever.
                     """)
    }

    /// T11 — `ERROR_INVALID_KEY` must **not** be read as "the peer wants nothing".
    ///
    /// Python has no branch for it: the int falls into `for tid in response` and raises, landing
    /// in the except at `:482-490`. Doing nothing is not an option here — the `default` arm this
    /// replaces marked every offered message handled, which loses them silently.
    func testAnInvalidKeyResponseKeepsTheMessagesUnhandled() throws {
        let peer = try syncAgainst(response: .uint(UInt64(LXMPeerError.invalidKey.rawValue)))

        XCTAssertEqual(peer.state, .idle)
        XCTAssertNil(peer.peeringKey, "the key the peer refused must be discarded and rebuilt")
        XCTAssertFalse(peer.unhandledMessages.isEmpty,
                       """
                       the peer refused our peering key and every offered message was marked \
                       handled anyway — they are now recorded as delivered to a node that never \
                       received them, and no retry will ever offer them again. This is the \
                       `default: return .noneWanted` arm reading a refusal as "wants nothing".
                       """)
        XCTAssertEqual(peer.offered, 0, "nothing was accepted, so nothing was offered")
    }

    /// T8 — `ERROR_NO_IDENTITY` re-identifies and sends the **same** offer again.
    func testANoIdentityResponseReIdentifiesAndResendsTheOffer() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())
        _ = try net.storeMessage(in: net.routerA, size: 400)

        var payloads: [MsgPack.Value] = []
        net.routerB.propagationDestination?.registerNativeRequestHandler(
            path: LXMPeer.offerRequestPath, allow: .all
        ) { _, value, _, _, _ in
            payloads.append(value)
            // Refuse the first as unidentified, accept-nothing on the retry.
            return payloads.count == 1
                ? .uint(UInt64(LXMPeerError.noIdentity.rawValue))
                : .bool(false)
        }

        net.routerA.syncPeers()
        _ = net.waitUntil("the offer is retried") { payloads.count >= 2 }

        XCTAssertEqual(payloads.count, 2,
                       """
                       the peer said it saw no identification and the offer was not retried \
                       (LXMPeer.py:408-414). Python identifies again and re-syncs immediately; \
                       dropping it means the same messages wait for the next scheduled pass.
                       """)
        XCTAssertEqual(payloads.first, payloads.last, "the retry offers the same messages")
    }

    /// T12 — the peer receives only what it lacks, and everything it already had is marked handled.
    func testThePeerReceivesOnlyTheMessagesItLacks() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())

        let shared = try net.storeMessage(in: net.routerA, size: 300)
        let onlyA1 = try net.storeMessage(in: net.routerA, size: 300)
        let onlyA2 = try net.storeMessage(in: net.routerA, size: 300)

        // B already holds `shared`, byte-identical.
        let sharedBytes = try net.storedBytes(in: net.routerA, transientID: shared)
        _ = net.routerB.addToMessageStore(lxmfData: sharedBytes.prefix(sharedBytes.count - 32),
                                          transientID: shared, stampValue: 0,
                                          stamp: sharedBytes.suffix(32))

        net.routerA.syncPeers()
        XCTAssertTrue(net.waitUntil("both missing messages land") {
            net.routerB.propagationEntries[onlyA1] != nil
                && net.routerB.propagationEntries[onlyA2] != nil
        }, "the two messages B lacked must arrive")

        XCTAssertEqual(peer.outgoing, 2, "only the two it wanted were transferred")
        XCTAssertEqual(peer.offered, 3, "but all three were offered")
        for tid in [shared, onlyA1, onlyA2] {
            XCTAssertTrue(peer.handledMessages.contains(tid),
                          """
                          a message the peer did not want is one it already has, from another \
                          peer — it must be marked handled, not offered again forever \
                          (LXMPeer.py:443-448).
                          """)
        }
    }

    // MARK: - The resource (design STEP 8)

    /// T13 — the resource carries `[timestamp, [fileBytes…]]` with the on-disk bytes **verbatim**,
    /// propagation stamp included. The client `/get` path deliberately strips it; this one must not.
    func testTheResourcePayloadIsATimestampAndVerbatimFileBytes() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())
        let tid = try net.storeMessage(in: net.routerA, size: 400)
        let onDisk = try net.storedBytes(in: net.routerA, transientID: tid)

        // Chained onto B's real handler, not substituted for it: that handler is what sets
        // `resourceStrategy = .acceptApp`, and a replacement that omits it makes B refuse the
        // resource — the test would then fail for a reason that has nothing to do with the payload.
        var captured: Data?
        let realHandler = net.routerB.propagationDestination?.onLinkEstablished
        net.routerB.propagationDestination?.onLinkEstablished = { link in
            realHandler?(link)
            let realConclusion = link.onResourceConcluded
            link.onResourceConcluded = { data, a, b in
                captured = data
                realConclusion?(data, a, b)
            }
        }

        net.routerA.syncPeers()
        _ = net.waitUntil("the resource arrives") { captured != nil }

        guard case .array(let outer) = try MsgPack.decode(try XCTUnwrap(captured)),
              outer.count == 2, case .double = outer[0],
              case .array(let bodies) = outer[1], case .bytes(let body) = bodies.first
        else {
            return XCTFail("the payload must be [float, [bytes…]] (LXMPeer.py:466)")
        }

        XCTAssertEqual(Data(body), onDisk,
                       """
                       the message file must ship verbatim. The receiver splits the last 32 bytes \
                       back off as the propagation stamp and validates it (LXStamper.py:84-96); \
                       stripping the stamp before sending — which is exactly what the *client* \
                       download path does at LXMRouter.swift:3207-3209 — makes every synced \
                       message fail the peer's stamp check.
                       """)
        XCTAssertEqual(Data(body).suffix(32), onDisk.suffix(32))
    }

    /// T14 — `txBytes` counts the **uncompressed** size, and a transfer rate is recorded.
    func testByteAccountingUsesTheUncompressedSize() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())
        // Highly compressible and large, so transferSize is far below dataSize.
        let tid = try net.storeMessage(in: net.routerA, size: 20_000, fill: 0x00)

        net.routerA.syncPeers()
        XCTAssertTrue(net.waitUntil("the message lands", timeout: 15) {
            net.routerB.propagationEntries[tid] != nil
        })

        let onDisk = try net.storedBytes(in: net.routerA, transientID: tid)
        let expected = MsgPack.encode(.array([.double(0), .array([.bytes(onDisk)])])).count
        XCTAssertEqual(peer.txBytes, expected, accuracy: 16,
                       """
                       `tx_bytes` accumulates `resource.get_data_size()` — the uncompressed \
                       payload (LXMPeer.py:518). Using the on-wire `transferSize` instead \
                       under-reports every compressible sync, and it is the number an operator \
                       reads to size a link.
                       """)
        XCTAssertGreaterThan(peer.syncTransferRate, 0,
                             """
                             no transfer rate was recorded. `syncPeers` ranks its candidate pool \
                             by `syncTransferRate` (LXMRouter.swift:3060), so while nothing \
                             writes it that ranking is inert and every peer looks equally slow.
                             """)
    }

    /// T17 — a persistent-strategy peer chains the next batch itself rather than waiting for the
    /// next scheduled pass.
    func testThePersistentStrategyChainsTheNextBatch() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())
        peer.syncStrategy = .persistent

        let first  = try net.storeMessage(in: net.routerA, size: 800)
        let second = try net.storeMessage(in: net.routerA, size: 800)
        // A sync limit that admits one message per offer, so a single pass cannot carry both
        // unless the machine re-syncs itself.
        peer.propagationSyncLimit = 1.0

        net.routerA.syncPeers()

        XCTAssertTrue(net.waitUntil("both messages land", timeout: 10) {
            net.routerB.propagationEntries[first] != nil
                && net.routerB.propagationEntries[second] != nil
        }, """
        one syncPeers pass delivered only part of the store. A persistent peer re-syncs itself \
        while work remains (LXMPeer.py:523-524); without it the rest waits for the next scheduled \
        pass, 24 s away, and a node with a backlog drains it one offer at a time.
        """)
    }

    // MARK: - Termination (design STEP 9)

    /// T15 — the remote tearing the link down returns the peer to idle.
    func testARemoteTeardownReturnsThePeerToIdle() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())
        _ = try net.storeMessage(in: net.routerA, size: 400)

        // Accept the link, never answer the offer, then tear it down from B's side.
        var responderLink: Link?
        net.routerB.propagationDestination?.registerNativeRequestHandler(
            path: LXMPeer.offerRequestPath, allow: .all
        ) { _, _, _, link, _ in
            responderLink = link
            return nil                      // no response — the sync is left hanging
        }

        net.routerA.syncPeers()
        _ = net.waitUntil("B has the link") { responderLink != nil }
        try XCTUnwrap(responderLink).teardown()

        XCTAssertTrue(net.waitUntil("the peer returns to idle", timeout: 3) {
            peer.state == .idle
        }, """
        the remote closed the sync link and the peer stayed mid-sync. `syncPeers` selects only \
        `state == .idle` (LXMRouter.swift:3038), so a peer left here is never dialled again — the \
        one thing `link_closed` (LXMPeer.py:544-546) exists to prevent.
        """)
        XCTAssertNil(peer.linkForTesting)
    }

    // MARK: - Helpers

    /// Run one full sync against a peer that answers the offer with `response`, and return A's
    /// peer entry. Used by the offer-response branch tests, which differ only in that value.
    @discardableResult
    private func syncAgainst(response: MsgPack.Value) throws -> LXMPeer {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()
        XCTAssertTrue(peer.generatePeeringKey())
        _ = try net.storeMessage(in: net.routerA, size: 400)

        var answered = false
        net.routerB.propagationDestination?.registerNativeRequestHandler(
            path: LXMPeer.offerRequestPath, allow: .all
        ) { _, _, _, _, _ in answered = true; return response }

        net.routerA.syncPeers()
        _ = net.waitUntil("the offer is answered") { answered }
        net.settle(0.4)
        return peer
    }
}
