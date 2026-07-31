import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/042` — a propagation node acquires peers from the syncs it receives.
///
/// Python peers on the incoming-sync path (`LXMF/LXMRouter.py:2366-2375`): on concluding a
/// propagation transfer from a remote it does not already know, it recalls that remote's announce
/// data and, if the data says "propagation node", autopeering is on and the remote is within
/// `autopeer_maxdepth` hops, it peers.
///
/// **Nothing in this file calls `addPeer`.** That is the point. Every existing peer test in the
/// package constructs its peers by hand (`LXMPropagationNodeTests.swift:289,297-298,314,322,354`),
/// which is why "no code path in `Sources/` creates a peer" was invisible for the life of the port
/// — a suite that builds the state under test cannot observe that production never builds it.
///
/// The upload goes through the real `Link` → `ResourceTransfer` → `onResourceConcluded` wiring
/// rather than calling the router's ingest method directly, so the seam these tests depend on (the
/// concluding link reaching the router, design D1) is exercised as production uses it.
final class PropagationPeeringTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_peering_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        retained.removeAll()
        super.tearDown()
    }

    // MARK: - The defect

    func testAnIncomingSyncFromAPropagationNodeCreatesAPeer() throws {
        let net = try makeNodeAndRemote()
        net.announceRemoteAsPropagationNode()
        net.seedPathToRemote(hops: 2)

        try net.uploadOneMessage()

        // Precondition, not the assertion under test: if the sync never reached the ingest path
        // there is nothing for peering to have happened on, and the failure below would say
        // "did not peer" about a broken harness.
        XCTAssertFalse(net.router.propagationEntries.isEmpty,
                       "the upload did not reach the node's store — the harness, not the defect",
                       file: #filePath, line: #line)

        XCTAssertNotNil(net.router.peers[net.remotePropagationHash],
                        """
                        the node concluded a propagation sync from a remote announcing itself as a \
                        propagation node 2 hops away, and did not peer with it \
                        (LXMRouter.py:2366-2375). Its peer table holds \
                        \(net.router.peers.count) peers.
                        """)
    }

    // MARK: - The gates
    //
    // Each of these fails against 1.4's implementation with only its own gate removed — not
    // against the pre-fix tree, where all three pass because no peer is ever created and a gate
    // that is present but never consulted would look identical to one that works.

    func testARemoteThatIsNotAPropagationNodeIsNotPeeredWith() throws {
        let net = try makeNodeAndRemote()
        net.announceRemoteAsSomethingElse()
        net.seedPathToRemote(hops: 2)

        try net.uploadOneMessage()

        XCTAssertNil(net.router.peers[net.remotePropagationHash],
                     """
                     the remote's announce data is not a propagation node's, so the node must not \
                     peer with it (LXMRouter.py:2357). A node that peers with every destination it \
                     receives a sync from will offer messages to things that cannot store them.
                     """)
    }

    func testANodeThatIsNoLongerActiveIsNotPeeredWith() throws {
        let net = try makeNodeAndRemote()
        // Valid propagation-node announce data, but the node-state flag is off — how the reference
        // signals a node that has disabled propagation (`disable_propagation` re-announces with
        // it false). Python gates on `pn_config[2]` (`:2365`).
        net.announceRemoteAsPropagationNode(nodeState: false)
        net.seedPathToRemote(hops: 2)

        try net.uploadOneMessage()

        XCTAssertNil(net.router.peers[net.remotePropagationHash],
                     "the remote announced propagation as disabled, so it must not be peered with")
    }

    func testAutopeeringDisabledPreventsPeering() throws {
        let net = try makeNodeAndRemote()
        net.router.autopeer = false
        net.announceRemoteAsPropagationNode()
        net.seedPathToRemote(hops: 2)

        try net.uploadOneMessage()

        XCTAssertNil(net.router.peers[net.remotePropagationHash],
                     """
                     autopeering is off and the node peered anyway — the setting the port \
                     documents in its own example configuration is not being read (bugs/042).
                     """)
    }

    func testANodeBeyondTheAutopeerDepthIsNotPeeredWith() throws {
        let net = try makeNodeAndRemote()
        net.announceRemoteAsPropagationNode()
        net.seedPathToRemote(hops: UInt8(LXMRouter.defaultAutopeerMaxdepth + 1))

        try net.uploadOneMessage()

        XCTAssertNil(net.router.peers[net.remotePropagationHash],
                     """
                     the remote is \(LXMRouter.defaultAutopeerMaxdepth + 1) hops away and the \
                     depth limit is \(LXMRouter.defaultAutopeerMaxdepth) (LXMRouter.py:2365).
                     """)
    }

    func testARemoteWithNoKnownPathIsNotPeeredWith() throws {
        let net = try makeNodeAndRemote()
        net.announceRemoteAsPropagationNode()
        // Deliberately no path seeded. Python's `Transport.hops_to` answers `PATHFINDER_M` (128)
        // for a destination it has no path to, so "unknown" fails the depth test. Swift's
        // `hopsTo` answers nil, and a nil that is read as "0 hops, very close" would peer with
        // every unreachable destination that ever synced.
        try net.uploadOneMessage()

        XCTAssertNil(net.router.peers[net.remotePropagationHash],
                     "an unknown hop count must fail the depth test, not pass it")
    }

    // MARK: - Harness

    /// A propagation node, a remote that syncs to it, and the announce/path state the node would
    /// have learned about that remote before the sync arrived.
    private struct Network {
        let router: LXMRouter
        let nodeTransport: Transport
        let remoteTransport: Transport
        let remoteIdentity: Identity
        let remotePropagationHash: Data
        let nodeInterface: any Interface
        let propagationDestination: Destination
        let uploadLink: Link
        unowned let test: PropagationPeeringTests

        /// Seed what the node would hold from having heard the remote's announce. Recalling
        /// non-nil app data is exactly what tells the reference the remote is a propagation node
        /// (`LXMRouter.py:2352,2357`).
        func announceRemoteAsPropagationNode(nodeState: Bool = true,
                                             peeringCost: Int = 0,
                                             timebase: Int64 = 1_700_000_000) {
            remoteIdentity.appData = Self.propagationAnnounceAppData(nodeState: nodeState,
                                                                     peeringCost: peeringCost,
                                                                     timebase: timebase)
            nodeTransport.restore(identity: remoteIdentity, forDestination: remotePropagationHash)
        }

        /// Announce data that is valid msgpack but not a propagation node's.
        func announceRemoteAsSomethingElse() {
            remoteIdentity.appData = MsgPack.encode(.array([.string("Some Node")]))
            nodeTransport.restore(identity: remoteIdentity, forDestination: remotePropagationHash)
        }

        func seedPathToRemote(hops: UInt8) {
            nodeTransport.injectPath(remotePropagationHash,
                                     nextHop: Data(repeating: 0x5A, count: 16),
                                     receivedOn: nodeInterface,
                                     hops: hops,
                                     announcePacketHash: nil)
        }

        /// The shape a peer sync has on the wire: `msgpack([timestamp, [lxmf_data + stamp]])`,
        /// delivered as a resource on the propagation link.
        func uploadOneMessage(content: String = "peer me") throws {
            let sourceIdentity = Identity()
            let source = try Destination(identity: sourceIdentity, direction: .in, kind: .single,
                                         appName: APP_NAME, aspects: ["delivery"])
            let destination = try Destination(identity: Identity(), direction: .in, kind: .single,
                                              appName: APP_NAME, aspects: ["delivery"])
            let message = LXMessage(destination: destination, source: source, content: content)
            try message.pack()
            let lxmfData = try XCTUnwrap(message.packed)
            let stamp = try XCTUnwrap(
                LXStamper.generateStamp(messageID: Hashes.fullHash(lxmfData), stampCost: 0))

            let payload = MsgPack.encode(.array([
                .double(Date().timeIntervalSince1970),
                .array([.bytes(lxmfData + stamp)]),
            ]))

            let uploaded = test.expectation(description: "propagation resource concluded")
            let sender = ResourceTransfer(link: uploadLink)
            sender.onComplete = { _ in uploaded.fulfill() }
            try sender.send(payload: payload)
            test.wait(for: [uploaded], timeout: 5.0)

            // The receiving side concludes on its own queue; give the router's callback a moment
            // to run before the assertion reads the table.
            let settled = test.expectation(description: "receiver settled")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
            test.wait(for: [settled], timeout: 2.0)
        }

        /// Python's `pn_config`, indices as read at `LXMRouter.py:2367-2373`.
        static func propagationAnnounceAppData(nodeState: Bool,
                                               peeringCost: Int,
                                               timebase: Int64) -> Data {
            MsgPack.encode(.array([
                .bool(false),                    // 0: legacy PN support flag
                .int(timebase),                  // 1: peering timebase
                .bool(nodeState),                // 2: node active flag
                .int(256),                       // 3: per-transfer limit
                .int(10240),                     // 4: per-sync limit
                .array([.int(0), .int(0), .int(Int64(peeringCost))]),   // 5: stamp costs
                .map([]),                        // 6: metadata
            ]))
        }
    }

    private var retained: [AnyObject] = []

    private func makeNodeAndRemote() throws -> Network {
        let nodeTransport   = Transport()
        let remoteTransport = Transport()
        retained.append(contentsOf: [nodeTransport, remoteTransport])

        let nodeIdentity   = Identity()
        let remoteIdentity = Identity()

        let router = LXMRouter(transport: nodeTransport)
        try router.register(identity: nodeIdentity, transport: nodeTransport)
        try router.enablePropagation(storagePath: tempDir)
        retained.append(router)

        let nodeInterface   = PeeringLoopInterface(name: "node")
        let remoteInterface = PeeringLoopInterface(name: "remote")
        nodeInterface.paired = remoteInterface
        remoteInterface.paired = nodeInterface
        nodeTransport.register(interface: nodeInterface)
        remoteTransport.register(interface: remoteInterface)

        let propagationDestination = try XCTUnwrap(router.propagationDestination)
        nodeTransport.register(destination: propagationDestination)

        // The remote's propagation destination — what the reference keys the peer table by
        // (`LXMRouter.py:2350-2351`).
        let remotePropagationHash = try Destination(identity: remoteIdentity, direction: .out,
                                                    kind: .single, appName: APP_NAME,
                                                    aspects: ["propagation"]).hash

        let localUp  = expectation(description: "remote side link established")
        let remoteUp = expectation(description: "node side link established")
        remoteTransport.onLinkEstablished = { _ in localUp.fulfill() }
        nodeTransport.onLinkEstablished   = { _ in remoteUp.fulfill() }
        let uploadLink = try Link.initiate(destination: propagationDestination,
                                           transport: remoteTransport)
        wait(for: [localUp, remoteUp], timeout: 3.0)

        // The remote identifies, which is how the node learns whose sync this is
        // (`LXMRouter.py:2348` reads `resource.link.get_remote_identity()`).
        let nodeSideLink = try XCTUnwrap(nodeTransport.links[try XCTUnwrap(uploadLink.linkID)])
        let identified = expectation(description: "node sees the remote's identity")
        nodeSideLink.onRemoteIdentified = { _, _ in identified.fulfill() }
        try uploadLink.identify(as: remoteIdentity)
        wait(for: [identified], timeout: 2.0)

        return Network(router: router,
                       nodeTransport: nodeTransport,
                       remoteTransport: remoteTransport,
                       remoteIdentity: remoteIdentity,
                       remotePropagationHash: remotePropagationHash,
                       nodeInterface: nodeInterface,
                       propagationDestination: propagationDestination,
                       uploadLink: uploadLink,
                       test: self)
    }
}

// MARK: - Loopback interface

private final class PeeringLoopInterface: Interface {
    let name: String
    var bitrate: Int = 1_000_000
    var isOnline: Bool = true
    var inboundHandler: ((Packet, any Interface) -> Void)?
    weak var paired: PeeringLoopInterface?

    init(name: String) { self.name = name }
    func start() throws { isOnline = true }
    func stop() { isOnline = false }

    func send(_ packet: Packet) throws {
        let raw  = try packet.pack()
        let copy = try Packet.unpack(raw)
        paired?.inboundHandler?(copy, paired!)
    }
}
