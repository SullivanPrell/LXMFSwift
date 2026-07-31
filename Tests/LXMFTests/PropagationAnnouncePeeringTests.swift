import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/046` — a propagation node peers with the propagation nodes it hears announce.
///
/// Python peers on two paths. `PropagationPeeringTests` covers the reactive one — the incoming-sync
/// path `bugs/042` named. This file covers the proactive one, `LXMF/Handlers.py:56-99`, which is the
/// path that *starts* the relationship.
///
/// The distinction is not academic. Peering is what causes a sync, and a sync is what causes
/// reactive peering, so an implementation with only the second half never begins: both nodes sit
/// with empty peer tables, each waiting for the other to upload first. Everything
/// `PropagationPeeringTests` asserts is unreachable between two nodes built on this port until this
/// path exists.
///
/// **The announce is delivered over the wire, not by calling the router.** The defect is precisely
/// that no registered handler consults a propagation announce — both of the port's handlers return
/// early unless the announce is from the node's own *outbound* PN (`Handlers.swift:104`,
/// `LXMRouter.swift:3390`). A test that reached past the handler and called a router method would
/// pass against the broken tree, because the router method is not what is missing.
final class PropagationAnnouncePeeringTests: XCTestCase {

    private var tempDirs: [String] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(atPath: dir) }
        tempDirs.removeAll()
        retained.removeAll()
        super.tearDown()
    }

    // MARK: - The defect

    func testAnAnnounceFromAPropagationNodeCreatesAPeer() throws {
        let net = try makeTwoNodes()

        try net.announceRemote()

        XCTAssertNotNil(net.node.peers[net.remotePropagationHash],
                        """
                        a propagation node heard another propagation node announce, one hop away, \
                        and did not peer with it (Handlers.py:80-91). Its peer table holds \
                        \(net.node.peers.count) peers.

                        This is the only path by which a node acquires a peer it has not already \
                        been contacted by. Without it the incoming-sync path cannot fire either — \
                        nothing ever syncs to a node whose peer table is empty — so both halves of \
                        autopeering are dead between two nodes built on this port.
                        """)
    }

    func testTheAnnouncedNodesAdvertisedTermsAreAdopted() throws {
        let net = try makeTwoNodes()
        net.remote.propagationStampCost = 9
        net.remote.peeringCost          = 0

        try net.announceRemote()

        let peer = try XCTUnwrap(net.node.peers[net.remotePropagationHash],
                                 "precondition: the announce created a peer")
        XCTAssertEqual(peer.propagationStampCost, 9,
                       """
                       the peer was created but its advertised stamp cost was not taken from the \
                       announce that created it. A peer whose required stamp cost reads 0 is one \
                       every message to it will be refused by.
                       """)
    }

    /// The other half of `Handlers.py:41-99`, and the half that was already implemented.
    ///
    /// It had no behavioural coverage: `HandlersTests` asserts the aspect filter, the
    /// path-response flag and that the router reference is held, and never calls
    /// `receivedAnnounce` at all. Deleting the trigger outright failed nothing in the package.
    /// It is asserted here because this file is where the handler's behaviour now lives.
    func testTheConfiguredOutboundNodeAnnouncingRetriesPropagatedMessagesNow() throws {
        let net = try makeTwoNodes()
        net.node.outboundPropagationNode = net.remotePropagationHash

        let queued = try net.queuePropagatedMessage()
        queued.nextDeliveryAttempt = Date().timeIntervalSince1970 + 3600
        XCTAssertGreaterThan(queued.nextDeliveryAttempt ?? 0, 0,
                             "precondition: the message is waiting on a retry timer")

        try net.announceRemote()

        XCTAssertEqual(queued.nextDeliveryAttempt, 0,
                       """
                       the configured outbound propagation node announced and the propagated \
                       message kept its retry timer (Handlers.py:46-54). The message then waits \
                       out a back-off that the announce just made unnecessary — the node is \
                       reachable now.
                       """)
    }

    // MARK: - The gates

    func testAPathResponseDoesNotCreateAPeer() throws {
        let net = try makeTwoNodes()
        // Without a known path this passes whatever the handler does, because an unknown hop count
        // already fails the depth test — the assertion would then be about path knowledge and not
        // about path responses at all. Seeding the path leaves exactly one reason to refuse.
        net.movePathToRemote(hops: 1)

        net.deliverAnnounceDirectly(isPathResponse: true)

        XCTAssertNil(net.node.peers[net.remotePropagationHash],
                     """
                     a path response is a replayed announce the node solicited itself, and Python \
                     gates autopeering on `not is_path_response` (Handlers.py:81). Peering off one \
                     means peering off an advertisement of unknown age.
                     """)
    }

    func testANodeThatHasDisabledPropagationIsUnpeered() throws {
        let net = try makeTwoNodes()
        try net.announceRemote()
        XCTAssertNotNil(net.node.peers[net.remotePropagationHash],
                        "precondition: the remote is a peer")

        net.deliverAnnounceDirectly(nodeState: false)

        XCTAssertNil(net.node.peers[net.remotePropagationHash],
                     """
                     the peer announced that it is no longer running propagation and was kept \
                     (Handlers.py:98-99). Retained, it is culled only after MAX_UNREACHABLE failed \
                     syncs — several sync intervals of dialling a node that said it was done.
                     """)
    }

    func testAPeerThatMovesBeyondTheAutopeerDepthIsUnpeered() throws {
        let net = try makeTwoNodes()
        try net.announceRemote()
        XCTAssertNotNil(net.node.peers[net.remotePropagationHash],
                        "precondition: the remote is a peer")

        // The mesh grew: the remote is now reachable only via a longer path than
        // `autopeerMaxdepth` allows. The default depth is left alone — moving the *node* is what
        // the reference's branch is about, and lowering the setting instead would pass against an
        // implementation that read the setting once at peering time.
        net.movePathToRemote(hops: UInt8(net.node.autopeerMaxdepth + 1))
        net.deliverAnnounceDirectly()

        XCTAssertNil(net.node.peers[net.remotePropagationHash],
                     """
                     an existing peer announced from beyond the autopeer depth and was kept \
                     (Handlers.py:93-96). The depth limit then bounds only which peers can be \
                     acquired, not which are held, so a table assembled while the mesh was small \
                     survives the mesh growing.
                     """)
    }

    func testAutopeeringDisabledPreventsPeeringOnTheAnnouncePath() throws {
        let net = try makeTwoNodes()
        net.node.autopeer = false

        try net.announceRemote()

        XCTAssertNil(net.node.peers[net.remotePropagationHash],
                     "autopeer is off and the announce path peered anyway (Handlers.py:81)")
    }

    func testAPlainClientDoesNotPeerWithTheNodesItHears() throws {
        let net = try makeTwoNodes()
        let client = LXMRouter(transport: net.nodeTransport)   // never enablePropagation
        retained.append(client)
        // In range and reachable, so the propagation-node guard is the only thing refusing.
        net.movePathToRemote(hops: 1)

        LXMFPropagationAnnounceHandler(router: client)
            .receivedAnnounce(destinationHash: net.remotePropagationHash,
                              identity: net.remoteIdentity,
                              appData: net.remote.getPropagationNodeAppData(),
                              announcePacketHash: Data(repeating: 0x00, count: 4),
                              isPathResponse: false)

        XCTAssertTrue(client.peers.isEmpty,
                      """
                      a router that is not a propagation node built a peer table from an announce. \
                      The reference gates the whole branch on `if self.lxmrouter.propagation_node` \
                      (Handlers.py:56) — a client has nothing to offer a peer and no store to sync \
                      from, so every entry is state it will dial and never use.
                      """)
    }

    // MARK: - Static peers

    func testAStaticPeerIsPeeredWithEvenWhenAutopeeringIsOff() throws {
        let net = try makeTwoNodes()
        net.node.autopeer = false
        net.node.staticPeers = [net.remotePropagationHash]

        try net.announceRemote()

        XCTAssertNotNil(net.node.peers[net.remotePropagationHash],
                        """
                        a statically configured peer announced and was not peered with. The \
                        reference handles static peers before the autopeer gate and never consults \
                        it (Handlers.py:68-78) — the operator already made that decision, and a \
                        node with autopeer off is exactly the node whose peers are all static.
                        """)
    }

    func testAStaticPeerAcceptsAPathResponseWhenItHasNeverBeenHeardFrom() throws {
        let net = try makeTwoNodes()
        net.node.staticPeers = [net.remotePropagationHash]

        net.deliverAnnounceDirectly(isPathResponse: true)

        XCTAssertNotNil(net.node.peers[net.remotePropagationHash],
                        """
                        a static peer that has never been heard from must take its terms from a \
                        path response (Handlers.py:70) — that response is how a peer which was \
                        offline at startup is learned at all, and refusing it leaves the peering \
                        configured but never activated.
                        """)
    }

    func testAStaticPeerAlreadyHeardFromIgnoresAPathResponse() throws {
        let net = try makeTwoNodes()
        net.node.staticPeers = [net.remotePropagationHash]
        try net.announceRemote()
        let heard = try XCTUnwrap(net.node.peers[net.remotePropagationHash]?.lastHeard,
                                  "precondition: the static peer was heard from")
        XCTAssertGreaterThan(heard, 0, "precondition: lastHeard was actually stamped")

        net.deliverAnnounceDirectly(isPathResponse: true, peeringCost: 3)

        XCTAssertNotEqual(net.node.peers[net.remotePropagationHash]?.peeringCost, 3,
                          """
                          a static peer that has been heard from took its terms from a path \
                          response. `Handlers.py:70` accepts one only while `last_heard == 0`: \
                          once the peer is live, a solicited replay of an old announce must not \
                          overwrite what it last actually said.
                          """)
    }

    // MARK: - Harness

    private var retained: [AnyObject] = []

    private struct Network {
        let node: LXMRouter
        let remote: LXMRouter
        let nodeTransport: Transport
        let nodeInterface: any Interface
        let remoteTransport: Transport
        let remotePropagationHash: Data
        let remoteIdentity: Identity
        unowned let test: PropagationAnnouncePeeringTests

        /// Announce the remote propagation node for real, over the interface pair, and wait for the
        /// node's transport to dispatch it to the registered handlers.
        ///
        /// Announced through `Transport.announce` rather than `router.announcePropagationNode()`
        /// because `Destination.announce` resolves its transport from `Reticulum.shared`
        /// (`Destination.swift:510`) and returns nil when there is none — two independent
        /// `Transport` instances is exactly the topology a peering test needs, and in it the
        /// router's own announce method is a silent no-op. The app data is the router's, so what
        /// travels is what a real node advertises.
        func announceRemote() throws {
            let dest = try XCTUnwrap(remote.propagationDestination)
            _ = try remoteTransport.announce(destination: dest,
                                             appData: remote.getPropagationNodeAppData())
            let settled = test.expectation(description: "announce dispatched")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
            test.wait(for: [settled], timeout: 2.0)
        }

        /// Hand an announce to the public handler with a chosen `isPathResponse` and node state.
        ///
        /// Only for the cases the wire cannot produce on demand — a path response, and a node
        /// announcing that it has *stopped* propagating. `testAnAnnounceFromAPropagationNodeCreatesAPeer`
        /// establishes that the registered handlers reach the same router method, so these are the
        /// same code path with one input varied.
        /// `timebase` defaults to a moment in the near future because `unpeer` refuses an
        /// announce older than the peering it would break (`LXMRouter.py:2049-2057`) — a fixed
        /// literal here would be older than the timebase the real announce carried, so the
        /// unpeer cases would pass for the wrong reason: stale, not disqualified.
        func deliverAnnounceDirectly(nodeState: Bool = true,
                                     isPathResponse: Bool = false,
                                     peeringCost: Int64 = 0,
                                     timebase: Int64? = nil) {
            let handler = LXMFPropagationAnnounceHandler(router: node)
            handler.receivedAnnounce(destinationHash: remotePropagationHash,
                                     identity: remoteIdentity,
                                     appData: Self.announceAppData(
                                         nodeState: nodeState,
                                         peeringCost: peeringCost,
                                         timebase: timebase
                                             ?? Int64(Date().timeIntervalSince1970) + 60),
                                     announcePacketHash: Data(repeating: 0x00, count: 4),
                                     isPathResponse: isPathResponse)
        }

        /// Put one PROPAGATED message on the node's outbound queue, waiting on a retry.
        func queuePropagatedMessage() throws -> LXMessage {
            let source = try XCTUnwrap(node.deliveryDestinations.values.first)
            let destination = try Destination(identity: Identity(), direction: .out, kind: .single,
                                              appName: APP_NAME, aspects: ["delivery"])
            let message = LXMessage(destination: destination, source: source, content: "queued")
            message.desiredMethod = .propagated
            try node.send(message)
            // `send` queues a propagated message only after generating its PN stamp, on a
            // background thread (`LXMRouter.swift:1105-1115`), so it is not on the queue when
            // `send` returns.
            let queued = test.expectation(description: "propagated message queued")
            DispatchQueue.global().async {
                while node.pendingOutbound.first(where: { $0 === message }) == nil {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                queued.fulfill()
            }
            test.wait(for: [queued], timeout: 5.0)
            return message
        }

        /// Re-file the path to the remote at a chosen hop count, as a topology change would.
        func movePathToRemote(hops: UInt8) {
            nodeTransport.injectPath(remotePropagationHash,
                                     nextHop: Data(repeating: 0x5A, count: 16),
                                     receivedOn: nodeInterface,
                                     hops: hops,
                                     announcePacketHash: nil)
        }

        /// `getPropagationNodeAppData`'s shape (`LXMRouter.py:1808-1821`).
        static func announceAppData(nodeState: Bool,
                                    peeringCost: Int64 = 0,
                                    timebase: Int64) -> Data {
            MsgPack.encode(.array([
                .nil,                       // [0] legacy enabled flag
                .int(timebase),             // [1] peering timebase
                .bool(nodeState),           // [2] currently propagating
                .int(0),                    // [3] per-transfer limit
                .int(0),                    // [4] per-sync limit
                .array([.int(0), .int(0), .int(peeringCost)]),  // [5] stamp cost, flex, peering cost
                .map([]),                   // [6] metadata
            ]))
        }
    }

    private func makeTwoNodes() throws -> Network {
        let nodeTransport   = Transport()
        let remoteTransport = Transport()
        retained.append(contentsOf: [nodeTransport, remoteTransport])

        let nodeInterface   = AnnounceLoopInterface(name: "node")
        let remoteInterface = AnnounceLoopInterface(name: "remote")
        nodeInterface.paired   = remoteInterface
        remoteInterface.paired = nodeInterface
        nodeTransport.register(interface: nodeInterface)
        remoteTransport.register(interface: remoteInterface)

        let node   = try makePropagationNode(on: nodeTransport,   suffix: "node")
        let remote = try makePropagationNode(on: remoteTransport, suffix: "remote")

        let remotePropagationHash = try XCTUnwrap(remote.propagationDestination).hash
        let remoteIdentity = try XCTUnwrap(remote.propagationDestination?.identity)

        return Network(node: node, remote: remote,
                       nodeTransport: nodeTransport,
                       nodeInterface: nodeInterface,
                       remoteTransport: remoteTransport,
                       remotePropagationHash: remotePropagationHash,
                       remoteIdentity: remoteIdentity,
                       test: self)
    }

    private func makePropagationNode(on transport: Transport, suffix: String) throws -> LXMRouter {
        let dir = NSTemporaryDirectory() + "lxmf_announce_peering_\(suffix)_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        let identity = Identity()
        let router = LXMRouter(transport: transport)
        try router.register(identity: identity, transport: transport)
        transport.ownerIdentity = identity
        router.peeringCost = 0
        try router.enablePropagation(storagePath: dir)
        retained.append(router)
        return router
    }
}

// MARK: - Loopback interface

private final class AnnounceLoopInterface: Interface {
    let name: String
    var bitrate: Int = 1_000_000
    var isOnline: Bool = true
    var inboundHandler: ((Packet, any Interface) -> Void)?
    weak var paired: AnnounceLoopInterface?

    init(name: String) { self.name = name }
    func start() throws { isOnline = true }
    func stop() { isOnline = false }

    func send(_ packet: Packet) throws {
        let raw  = try packet.pack()
        let copy = try Packet.unpack(raw)
        paired?.inboundHandler?(copy, paired!)
    }
}
