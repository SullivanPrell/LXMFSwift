import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/020` — the client sync state machine's answer to its link closing.
///
/// Python maps a closed outbound propagation link onto the sync state machine in `clean_links`
/// (`LXMRouter.py:991-1000`): `PR_COMPLETE` acknowledges to idle, anything before
/// `PR_LINK_ESTABLISHED` fails as `PR_LINK_FAILED`, anything between established and complete
/// fails as `PR_TRANSFER_FAILED` — all through `acknowledge_sync_completion` (`:1656`). The port
/// had none of it: `onClosed` cleared the link reference and left `propagationTransferState`
/// wherever it was, so "Sync Now" against an unreachable node spun for the lifetime of the
/// process (`RetiOS` polls that state and exits only on `.done` or `.failed`).
///
/// `LXMPropagationSyncTests` covers a dozen **response-level** failures; the hole was the
/// **link-level** one — the case a real user hits first.
///
/// The wire is the synchronous `PeerSyncLoopInterface`, so every stage of a sync completes
/// inside the call that starts it; parking the machine at a chosen pre-close state is done by
/// dropping packets, not by assigning states — an assigned state would test the assignment.
final class PropagationSyncTests: XCTestCase {

    private var tempDir: String!
    private var net: PeerOutboundSyncNetwork!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_propsync_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        net = nil
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    /// A learns B over the wire and selects B as its outbound propagation node.
    private func makeClient() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 2)
        try net.announceBToA()
        net.routerA.outboundPropagationNode = net.bPropagationHash
    }

    // MARK: - 6.3: link closure reaches a terminal state, from both pre-close phases

    /// Closure point one: before the link is established (`state < PR_LINK_ESTABLISHED` →
    /// `PR_LINK_FAILED`). The wire is held so the LINKREQUEST never arrives; the teardown is
    /// what the RNS link watchdog does to an unanswered link, minus the wait.
    func testLinkClosureBeforeEstablishmentFailsTheSync() throws {
        try makeClient()
        net.interfaceA.isBlackholed = true

        net.routerA.requestMessagesFromPropagationNode(identity: net.identityA)
        XCTAssertEqual(net.routerA.propagationTransferState, .linkEstablishing,
                       "precondition: the machine must actually be mid-establishment")
        let link = try XCTUnwrap(net.routerA.outboundPropagationLink)

        try link.teardown()
        net.settle(0.2)

        XCTAssertEqual(net.routerA.propagationTransferState, .failed,
                       """
                       the link died before establishment and the sync state never became \
                       terminal — a UI polling for `.done` or `.failed` polls forever \
                       (`LXMRouter.py:996-997` maps this to PR_LINK_FAILED)
                       """)
        XCTAssertNil(net.routerA.outboundPropagationLink,
                     "the reference also clears the link reference (`LXMRouter.py:992`)")
    }

    /// Closure point two: after establishment, mid-transfer (`PR_LINK_ESTABLISHED ≤ state <
    /// PR_COMPLETE` → `PR_TRANSFER_FAILED`). The link proof passes; every later reply from the
    /// node is dropped, parking the client at `.requestSent` with a live link.
    func testLinkClosureMidTransferFailsTheSync() throws {
        try makeClient()
        net.interfaceB.dropOutbound = { $0.packetType != .proof }

        net.routerA.requestMessagesFromPropagationNode(identity: net.identityA)
        XCTAssertEqual(net.routerA.propagationTransferState, .requestSent,
                       "precondition: established, request out, no response — mid-transfer")
        let link = try XCTUnwrap(net.routerA.outboundPropagationLink)

        try link.teardown()
        net.settle(0.2)

        XCTAssertEqual(net.routerA.propagationTransferState, .failed,
                       """
                       the link died mid-transfer and the sync state never became terminal \
                       (`LXMRouter.py:998-999` maps this to PR_TRANSFER_FAILED)
                       """)
        XCTAssertNil(net.routerA.outboundPropagationLink)
    }

    /// The reference's `PR_COMPLETE` branch: a *completed* sync whose link then closes
    /// acknowledges back to `.idle` (`LXMRouter.py:993-994`) — closure after success is
    /// housekeeping, not a failure. Against B's empty store the whole sync completes inside
    /// the request call on this wire.
    func testCompletedSyncAcknowledgesToIdleWhenTheLinkCloses() throws {
        try makeClient()

        net.routerA.requestMessagesFromPropagationNode(identity: net.identityA)
        XCTAssertEqual(net.routerA.propagationTransferState, .done,
                       "precondition: an empty-store sync completes inline on this wire")
        let link = try XCTUnwrap(net.routerA.outboundPropagationLink,
                                 "completion must not tear the link down by itself")

        try link.teardown()
        net.settle(0.2)

        XCTAssertEqual(net.routerA.propagationTransferState, .idle,
                       "a completed sync's link closing is Python's PR_COMPLETE → ack → PR_IDLE, "
                       + "not a failure")
        XCTAssertNil(net.routerA.outboundPropagationLink)
    }

    /// Negative control for the two failure tests: a *deliberate* cancel must stay `.idle` when
    /// its own teardown's `onClosed` fires afterwards. The reference gets this for free because
    /// `cancel_propagation_node_requests` clears the link reference *before* tearing down, so
    /// `clean_links` finds nothing to map — the port's closure handler must keep that guard.
    /// (Passes before the fix too, because the unfixed handler does nothing at all; it is
    /// meaningful only beside the failure tests above, and pins the guard once they are green.)
    func testCancelDoesNotReadAsFailure() throws {
        try makeClient()
        net.interfaceA.isBlackholed = true

        net.routerA.requestMessagesFromPropagationNode(identity: net.identityA)
        XCTAssertEqual(net.routerA.propagationTransferState, .linkEstablishing)

        net.routerA.cancelPropagationNodeRequests()
        XCTAssertEqual(net.routerA.propagationTransferState, .idle)

        net.settle(0.3)
        XCTAssertEqual(net.routerA.propagationTransferState, .idle,
                       "the cancel's own teardown callback re-marked a deliberate cancel as "
                       + "a failure")
    }

    /// The periodic safety net, Python's letter: `clean_links` itself maps a closed outbound
    /// link even when the closure callback never ran — here because something clobbered
    /// `onClosed`, which is exactly how `bugs/021`'s neighbouring defect (an unchained handler)
    /// would present.
    func testCleanLinksMapsAClosedOutboundLinkTheCallbackMissed() throws {
        try makeClient()
        net.interfaceB.dropOutbound = { $0.packetType != .proof }

        net.routerA.requestMessagesFromPropagationNode(identity: net.identityA)
        XCTAssertEqual(net.routerA.propagationTransferState, .requestSent)
        let link = try XCTUnwrap(net.routerA.outboundPropagationLink)

        link.onClosed = nil
        try link.teardown()
        net.settle(0.2)
        XCTAssertEqual(net.routerA.propagationTransferState, .requestSent,
                       "precondition: with the callback gone, only the periodic pass can see this")

        net.routerA.cleanLinks()
        net.settle(0.2)

        XCTAssertEqual(net.routerA.propagationTransferState, .failed,
                       "`clean_links` is the reference's own mechanism (`LXMRouter.py:991-1000`); "
                       + "the event-driven handler is an addition, not a replacement")
        XCTAssertNil(net.routerA.outboundPropagationLink)
    }

    // MARK: - 6.5: a sync that neither completes nor sees closure terminates

    /// A live link whose transfer has simply stopped moving: no closure will ever fire and no
    /// response will ever come. The reference has nothing for this case — its watchdog only
    /// catches links that *die* — so the bound is a port-side safety net, checked on the same
    /// periodic pass as the closure mapping. The parameter exists so the test does not wait out
    /// the production bound, the same shape as `cleanLinks(peerSyncMaxInactivity:)`.
    func testStalledSyncTerminates() throws {
        try makeClient()
        net.interfaceB.dropOutbound = { $0.packetType != .proof }

        net.routerA.requestMessagesFromPropagationNode(identity: net.identityA)
        XCTAssertEqual(net.routerA.propagationTransferState, .requestSent)
        XCTAssertEqual(net.routerA.outboundPropagationLink?.status, .active,
                       "precondition: the link is alive — this is a stall, not a closure")

        net.settle(0.25)
        net.routerA.cleanLinks(syncStallTimeout: 0.1)
        net.settle(0.2)

        XCTAssertEqual(net.routerA.propagationTransferState, .failed,
                       "a sync with no activity past the bound must terminate, or a misbehaving "
                       + "node hangs every caller that waits on a terminal state")
        XCTAssertNil(net.routerA.outboundPropagationLink,
                     "the stalled link is torn down, as the reference tears links down on "
                     + "request failure (`message_get_failed`, `LXMRouter.py:1651-1654`)")
    }

    /// The stall bound must not fire on a sync that is merely *slow*: activity refreshes it.
    func testActivityRefreshesTheStallBound() throws {
        try makeClient()
        net.interfaceB.dropOutbound = { $0.packetType != .proof }

        net.routerA.requestMessagesFromPropagationNode(identity: net.identityA)
        XCTAssertEqual(net.routerA.propagationTransferState, .requestSent)

        // Something happened just now: the machine touched its transfer progress.
        net.routerA.propagationTransferProgress = 0.5
        net.routerA.cleanLinks(syncStallTimeout: 5.0)
        net.settle(0.1)

        XCTAssertEqual(net.routerA.propagationTransferState, .requestSent,
                       "recent activity must keep a slow sync alive — the bound is for stalls, "
                       + "not for patience")
        XCTAssertNotNil(net.routerA.outboundPropagationLink)
    }
}
