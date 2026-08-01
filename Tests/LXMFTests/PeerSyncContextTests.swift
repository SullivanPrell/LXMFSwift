import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/054`, step 3 — the context seam.
///
/// `LXMRouter.transport` is `private` and `LXMPeer` lives in another file. That is the structural
/// reason the outbound port stopped at a comment: the peer could not reach a transport to dial
/// with. `makePeerSyncContext` is the one place the outbound path touches the outside world, and
/// `PeerSyncContext` has no defaulted members and no back-pointer to the router — so a future
/// dependency forces the single construction site to supply it, and no code can reach around it.
final class PeerSyncContextTests: XCTestCase {

    func testContextResolvesTheRemotePropagationDestination() throws {
        let net = try makeTwoRouters()

        let ctx = try XCTUnwrap(net.routerA.makePeerSyncContext(for: net.peerB),
                                "B's identity is recallable and it has a propagation destination")

        XCTAssertEqual(ctx.destination.hash, net.bPropagationHash,
                       """
                       the context must resolve the peer's *propagation* destination — the same \
                       hash the peer table is keyed by (LXMPeer.py:220-225). A destination built \
                       from another aspect has a different hash, so the link request goes \
                       somewhere that will never answer.
                       """)
        XCTAssertEqual(ctx.peerIdentity.hash, net.bIdentity.hash)
        XCTAssertEqual(ctx.routerIdentity.hash, net.aIdentity.hash)
    }

    func testTheContextResolvesFromTheDestinationHashItWasGiven() throws {
        let net = try makeTwoRouters()
        let ctx = try XCTUnwrap(net.routerA.makePeerSyncContext(for: net.peerB))

        // Python's late resolution (`LXMPeer.py:305`) reads an unqualified `destination_hash` —
        // a NameError upstream. Resolving from `peer.destinationHash` is what makes that
        // unreachable here rather than merely unlikely.
        XCTAssertEqual(ctx.destination.hash, net.peerB.destinationHash)
    }

    func testAPeerWhoseIdentityCannotBeRecalledHasNoContext() throws {
        let net = try makeTwoRouters()
        let stranger = net.routerA.addPeer(destinationHash: Data(repeating: 0x99, count: 16))

        XCTAssertNil(net.routerA.makePeerSyncContext(for: stranger),
                     """
                     no identity means no destination to dial and no peering material to compute. \
                     Python logs and returns (LXMPeer.py:392-393); returning a context with a \
                     placeholder identity would compute a peering key over the wrong material.
                     """)
    }

    func testARouterWithNoIdentityHasNoContext() throws {
        let net = try makeTwoRouters()
        let bare = LXMRouter(transport: net.transportA)
        let peer = bare.addPeer(destinationHash: net.bPropagationHash)

        XCTAssertNil(bare.makePeerSyncContext(for: peer),
                     "without a local identity there is no sender half of the peering material")
    }

    // MARK: - What the context carries

    func testTheContextReadsStoredMessageBytesFromDisk() throws {
        let net = try makeTwoRouters()
        let ctx = try XCTUnwrap(net.routerA.makePeerSyncContext(for: net.peerB))

        let body  = Data(repeating: 0x42, count: 64)
        let stamp = Data(repeating: 0xA7, count: 32)
        let tid = try storeMessage(in: net.routerA, body: body, stamp: stamp)

        let readBack = try XCTUnwrap(ctx.messageBytes(tid))
        XCTAssertEqual(readBack, body + stamp,
                       """
                       the sync resource ships the on-disk file verbatim (LXMPeer.py:459-464): \
                       LXMF bytes with the 32-byte propagation stamp still appended, because the \
                       receiver splits it back off to validate it (LXStamper.py:84-96). Returning \
                       only the LXMF bytes — which is what the *client* download path does \
                       deliberately — makes every synced message fail the peer's stamp check.
                       """)
        XCTAssertTrue(ctx.entryExists(tid))
        XCTAssertEqual(ctx.size(tid), readBack.count, "the size limits are measured on what is sent")
    }

    func testTheContextReportsAMissingMessageRatherThanFailing() throws {
        let net = try makeTwoRouters()
        let ctx = try XCTUnwrap(net.routerA.makePeerSyncContext(for: net.peerB))

        let absent = Data(repeating: 0xEE, count: 32)
        XCTAssertNil(ctx.messageBytes(absent))
        XCTAssertFalse(ctx.entryExists(absent))
    }

    func testTheThrottleWaitIsTheRoutersOwn() throws {
        let net = try makeTwoRouters()
        let ctx = try XCTUnwrap(net.routerA.makePeerSyncContext(for: net.peerB))

        XCTAssertEqual(ctx.throttleWait, LXMRouter.pnStampThrottle,
                       "a throttled peer is postponed by PN_STAMP_THROTTLE (LXMPeer.py:421-425)")
    }

    // MARK: - Harness

    private struct TwoRouters {
        let routerA: LXMRouter
        let peerB: LXMPeer
        let transportA: Transport
        let aIdentity: Identity
        let bIdentity: Identity
        let bPropagationHash: Data
    }

    private var retained: [AnyObject] = []
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_syncctx_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        retained.removeAll()
        super.tearDown()
    }

    private func makeTwoRouters() throws -> TwoRouters {
        let transportA = Transport()
        let aIdentity  = Identity()
        let bIdentity  = Identity()
        retained.append(transportA)

        let routerA = LXMRouter(transport: transportA)
        routerA.propagationStampCost = 0
        try routerA.register(identity: aIdentity, transport: transportA)
        try routerA.enablePropagation(storagePath: tempDir)
        retained.append(routerA)

        // B's propagation destination, and its identity known to A's transport — which is what a
        // received announce would have done.
        let bPropagation = try Destination(identity: bIdentity, direction: .out, kind: .single,
                                           appName: APP_NAME, aspects: ["propagation"])
        transportA.restore(identity: bIdentity, forDestination: bPropagation.hash)

        let peerB = routerA.addPeer(destinationHash: bPropagation.hash)

        return TwoRouters(routerA: routerA, peerB: peerB, transportA: transportA,
                          aIdentity: aIdentity, bIdentity: bIdentity,
                          bPropagationHash: bPropagation.hash)
    }

    private func storeMessage(in router: LXMRouter, body: Data, stamp: Data) throws -> Data {
        let tid = Hashes.fullHash(body)
        _ = router.addToMessageStore(lxmfData: body, transientID: tid,
                                     stampValue: 0, stamp: stamp)
        return tid
    }
}
