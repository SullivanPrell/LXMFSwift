import XCTest
@testable import LXMF
import ReticulumSwift

/// Two real propagation nodes on one synchronous wire, for `swift_devel/bugs/054`.
///
/// **The observable is always B's message store**, never A's `state`. That is the whole point of
/// this file: the defect it exists to catch is a machine that sets its own state variables and
/// never puts a byte on the wire, and `state == .linkEstablishing` is exactly what the stub
/// already did. A test that asserts A's state cannot tell the two apart.
///
/// The wire is `PeerSyncLoopInterface`, which delivers on the caller's thread. That is deliberate:
/// it means the entire outbound machine — dial, identify, offer, response, resource, teardown —
/// can complete *inside* `Link.initiate`, and any state write placed after a callout will stomp a
/// later transition. Over a real network the same code works either way, so a synchronous wire is
/// the only cheap way to observe the ordering bug at all.
final class PeerOutboundSyncNetwork {

    let routerA: LXMRouter          // the sender: holds messages, initiates the sync
    let routerB: LXMRouter          // the receiver: a real propagation node
    let transportA: Transport
    let transportB: Transport
    let identityA: Identity
    let identityB: Identity
    let aPropagationHash: Data
    let bPropagationHash: Data
    let interfaceA: PeerSyncLoopInterface
    let interfaceB: PeerSyncLoopInterface

    /// A's peer entry for B — the one an outbound sync runs against.
    var peerB: LXMPeer { routerA.peers[bPropagationHash]! }

    /// B's peer entry for A, once B has heard A announce.
    var peerA: LXMPeer? { routerB.peers[aPropagationHash] }

    private let tempDir: String
    private unowned let test: XCTestCase

    /// - Parameter peeringCost: the cost B advertises, which A must satisfy with real
    ///   proof of work. Capped hard — see the `precondition` below.
    init(test: XCTestCase, tempDir: String, peeringCost: Int = 4,
         syncStrategy: LXMSyncStrategy = .persistent) throws {
        // A test that accidentally takes the default cost of 18 (`LXMRouter.py:50`) runs ~2^18
        // SHA-256 over a 6400-byte workblock per peering and looks like a hang. The next person
        // "fixes" it by hand-assigning a peering key — which reintroduces exactly the fabricated
        // fixture that made "no writer exists anywhere in Sources/" invisible for a year.
        precondition(peeringCost <= 8,
                     "peering PoW in a test must stay cheap; hand-assigning a key is not the fix")

        self.test = test
        self.tempDir = tempDir

        transportA = Transport()
        transportB = Transport()
        identityA  = Identity()
        identityB  = Identity()

        let storageA = tempDir + "/a"
        let storageB = tempDir + "/b"
        for path in [storageA, storageB] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }

        routerA = LXMRouter(transport: transportA)
        routerB = LXMRouter(transport: transportB)

        // Both nodes accept a stamp of any value: `minCost = max(0, cost - flexibility) = 0`
        // (`LXMRouter.swift:2258`), so the cost-0 stamps these tests store are offered and
        // ingested. The point under test is the sync machine, not stamp economics — and the
        // reference allows it, since PROPAGATION_COST_MIN clamps the constructor argument, not a
        // later assignment (`LXMRouter.py:136` vs `:147`).
        for router in [routerA, routerB] {
            router.propagationStampCost = 0
            router.propagationStampCostFlexibility = 0
            router.peeringCost = peeringCost
        }

        try routerA.register(identity: identityA, transport: transportA)
        try routerB.register(identity: identityB, transport: transportB)
        try routerA.enablePropagation(storagePath: storageA)
        try routerB.enablePropagation(storagePath: storageB)

        interfaceA = PeerSyncLoopInterface(name: "a")
        interfaceB = PeerSyncLoopInterface(name: "b")
        interfaceA.paired = interfaceB
        interfaceB.paired = interfaceA
        transportA.register(interface: interfaceA)
        transportB.register(interface: interfaceB)

        aPropagationHash = routerA.propagationDestination!.hash
        bPropagationHash = routerB.propagationDestination!.hash

        // Each node serves its own propagation destination, which is what makes an inbound link
        // request answerable.
        transportA.register(destination: routerA.propagationDestination!)
        transportB.register(destination: routerB.propagationDestination!)

        self.defaultSyncStrategy = syncStrategy
    }

    private let defaultSyncStrategy: LXMSyncStrategy

    // MARK: - Peering

    /// Announce B to A over the wire, so A learns B's identity, its terms and a path to it.
    ///
    /// Through the real announce handler rather than `routerA.peer(destinationHash:…)`, because
    /// that is the path that feeds `peeringCost` into the peer — and a peer with no cost never
    /// generates a key, which is the first guard the machine hits.
    @discardableResult
    func announceBToA() throws -> LXMPeer {
        try announce(routerB, on: transportB)
        let peer = try XCTUnwrap(routerA.peers[bPropagationHash],
                                 "A must peer with B off the announce before it can sync to it")
        peer.seedSyncState(syncStrategy: defaultSyncStrategy)
        return peer
    }

    /// Announce A to B, so B can peer back. Needed only where the test cares about B's peer table.
    func announceAToB() throws {
        try announce(routerA, on: transportA)
    }

    private func announce(_ router: LXMRouter, on transport: Transport) throws {
        let destination = try XCTUnwrap(router.propagationDestination)
        // `Transport.announce`, not `router.announcePropagationNode()`: `Destination.announce`
        // resolves its transport from `Reticulum.shared` (`Destination.swift:510`) and silently
        // returns nil when there is none. Two independent transports is precisely the topology
        // here. The app data is the router's own, so what travels is what a real node advertises.
        _ = try transport.announce(destination: destination,
                                   appData: router.getPropagationNodeAppData())
        settle(0.3)
    }

    // MARK: - The message store

    /// Store a message in `router` through the real ingest path, and mark it unhandled for every
    /// peer — which is what `addToMessageStore` plus peer distribution does in production.
    ///
    /// Returns the transient ID. The body is unique per call so two messages never collide.
    @discardableResult
    func storeMessage(in router: LXMRouter, size: Int = 400, fill: UInt8? = nil) throws -> Data {
        let marker = fill ?? UInt8.random(in: 1...255)
        var body = Data(repeating: marker, count: max(size, LXMessage.destinationLength + 1))
        body.replaceSubrange(0..<8, with: UUID().uuidString.prefix(8).utf8)

        let stamp = Data(repeating: 0x00, count: 32)
        let tid = Hashes.fullHash(body)
        _ = router.addToMessageStore(lxmfData: body, transientID: tid, stampValue: 0, stamp: stamp)

        for peer in router.peers.values {
            peer.queueUnhandledMessage(tid)
            peer.processQueues()
        }
        return tid
    }

    /// The bytes as written to disk: LXMF data with the 32-byte propagation stamp appended.
    func storedBytes(in router: LXMRouter, transientID: Data) throws -> Data {
        let path = try XCTUnwrap(router.peerEntry(transientID)?.filePath)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    // MARK: - Waiting

    /// Poll until `condition` holds, then return true; false on timeout.
    ///
    /// Polling, not an expectation, because the thing being waited on is a dictionary in another
    /// router with no callback to hang a fulfilment off — and inventing one would mean adding a
    /// production hook that exists only for this suite.
    @discardableResult
    func waitUntil(_ description: String, timeout: TimeInterval = 5.0,
                   _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Let queued work drain. Used after an action whose effect is an *absence*.
    func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

// MARK: - The wire

/// A synchronous loopback pair. `send` delivers on the caller's thread, which is what lets a whole
/// sync complete inside `Link.initiate` — see the note on `PeerOutboundSyncNetwork`.
final class PeerSyncLoopInterface: Interface {
    let name: String
    var bitrate: Int = 1_000_000
    var isOnline: Bool = true
    var inboundHandler: ((Packet, any Interface) -> Void)?
    weak var paired: PeerSyncLoopInterface?

    /// Every packet this interface was asked to send, for tests that assert a path request went out.
    private(set) var sent: [Packet] = []
    private let lock = NSLock()

    /// When set, `send` records the packet and drops it. Used to hold a link half-open.
    var isBlackholed = false

    /// When set, `send` drops any packet the predicate matches. Finer-grained than
    /// `isBlackholed`: on a synchronous wire a whole exchange completes inside one call, so
    /// holding a sync at a *chosen* stage means the drop decision has to be per-packet — e.g.
    /// "let the link proof through, drop the request responses" parks the far side's client at
    /// `.requestSent` (`swift_devel/bugs/020`'s mid-transfer closure point).
    var dropOutbound: ((Packet) -> Bool)?

    init(name: String) { self.name = name }
    func start() throws { isOnline = true }
    func stop() { isOnline = false }

    func send(_ packet: Packet) throws {
        lock.lock()
        sent.append(packet)
        let dropping = isBlackholed || (dropOutbound?(packet) ?? false)
        lock.unlock()
        guard !dropping else { return }
        let raw  = try packet.pack()
        let copy = try Packet.unpack(raw)
        paired?.inboundHandler?(copy, paired!)
    }

    /// Path requests are plain packets addressed to the well-known path-request destination.
    func sentPathRequests() -> [Packet] {
        lock.lock(); defer { lock.unlock() }
        return sent.filter { $0.destinationHash == Transport.pathRequestDestinationHash }
    }

    func clearSent() {
        lock.lock(); sent.removeAll(); lock.unlock()
    }
}
