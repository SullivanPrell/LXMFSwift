import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/044` — a node throttles a remote that sends messages with invalid stamps, and
/// says so on the wire.
///
/// Python sets the throttle for `PN_STAMP_THROTTLE` (180 s) when a transfer contains any
/// invalid-stamp message and tears the link down (`LXMRouter.py:2447-2454`); checks it at the top
/// of the offer handler and answers `ERROR_THROTTLED` while it holds (`:2285-2290`); and expires
/// entries on the job loop (`:1136-1142`).
///
/// The port already decodes that error as a *client* (`LXMPeer.swift:58,692`) and has no path that
/// emits it, so the divergence is one-sided and silent: a Python node answers a misconfigured
/// client with an actionable refusal, and this port answers with an ordinary acceptance.
///
/// Everything here drives the real registered request handler over a real link, rather than calling
/// the router's methods — the throttle is keyed by the remote's *propagation destination* hash
/// (`:2269-2270`), which cannot be derived from the identity hash the internal handler was being
/// given, so a test that called it directly would be testing a different question.
final class PropagationThrottleTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_throttle_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        retained.removeAll()
        super.tearDown()
    }

    // MARK: - Setting the throttle

    func testAnInvalidStampTransferThrottlesTheSender() throws {
        let net = try makeNodeAndRemote()
        try net.upload(stampIsValid: false)

        let answer = try net.makeOffer()

        XCTAssertEqual(answer, .int(Int64(LXMPeerError.throttled.rawValue)),
                       """
                       the remote's last transfer contained a message whose stamp did not \
                       validate, and its next offer was answered normally (LXMRouter.py:2285-2290). \
                       With no back-off the same transfer can be retried at whatever rate the \
                       remote chooses, and each attempt costs full stamp validation over the whole \
                       message set.
                       """)
    }

    func testAValidTransferThrottlesNobody() throws {
        let net = try makeNodeAndRemote()
        try net.upload(stampIsValid: true)

        let answer = try net.makeOffer()

        XCTAssertNotEqual(answer, .int(Int64(LXMPeerError.throttled.rawValue)),
                          "a remote whose stamps all validate must not be throttled")
    }

    func testTheThrottleIsKeyedByThePropagationDestinationNotTheIdentity() throws {
        let net = try makeNodeAndRemote()
        try net.upload(stampIsValid: false)

        XCTAssertNotNil(net.router.throttledPeers[net.remotePropagationHash],
                        """
                        the throttle must be filed under the remote's propagation destination hash \
                        (LXMRouter.py:2269-2270), which is what the offer handler looks it up by. \
                        Filed under the identity hash it would be set and never found.
                        """)
    }

    // MARK: - Expiry

    func testAThrottledRemoteIsAcceptedAgainOnceThePeriodElapses() throws {
        let net = try makeNodeAndRemote()
        try net.upload(stampIsValid: false)
        XCTAssertEqual(try net.makeOffer(), .int(Int64(LXMPeerError.throttled.rawValue)),
                       "precondition: the remote is throttled")

        // Wind the deadline back rather than waiting out PN_STAMP_THROTTLE's 180 seconds.
        net.router.throttledPeers[net.remotePropagationHash] = Date().timeIntervalSince1970 - 1

        let answer = try net.makeOffer()

        XCTAssertNotEqual(answer, .int(Int64(LXMPeerError.throttled.rawValue)),
                          "an elapsed throttle must stop applying (LXMRouter.py:2287-2290)")
        XCTAssertNil(net.router.throttledPeers[net.remotePropagationHash],
                     "and the expired entry must be dropped when it is encountered")
    }

    func testAnExpiredRecordIsRemovedWithoutTheRemoteReturning() throws {
        let net = try makeNodeAndRemote()
        try net.upload(stampIsValid: false)
        net.router.throttledPeers[net.remotePropagationHash] = Date().timeIntervalSince1970 - 1

        net.router.cleanThrottledPeers()

        XCTAssertTrue(net.router.throttledPeers.isEmpty,
                      """
                      the offer handler drops an expired entry only for a remote that comes back. \
                      Without the scheduled sweep (LXMRouter.py:1136-1142, called from jobs() at \
                      :910) the table accumulates entries for remotes that never do.
                      """)
    }

    func testALiveThrottleSurvivesTheSweep() throws {
        let net = try makeNodeAndRemote()
        try net.upload(stampIsValid: false)

        net.router.cleanThrottledPeers()

        XCTAssertNotNil(net.router.throttledPeers[net.remotePropagationHash],
                        "the sweep must remove expired entries only, not clear the table")
    }

    // MARK: - Harness

    private var retained: [AnyObject] = []

    private struct Network {
        let router: LXMRouter
        let remotePropagationHash: Data
        let link: Link
        unowned let test: PropagationThrottleTests

        /// Upload one message as a propagation sync, with a stamp that either meets the node's
        /// required cost or does not.
        func upload(stampIsValid: Bool) throws {
            let source = try Destination(identity: Identity(), direction: .in, kind: .single,
                                         appName: APP_NAME, aspects: ["delivery"])
            let destination = try Destination(identity: Identity(), direction: .in, kind: .single,
                                              appName: APP_NAME, aspects: ["delivery"])
            let message = LXMessage(destination: destination, source: source, content: "throttle me")
            try message.pack()
            let lxmfData = try XCTUnwrap(message.packed)

            let stamp: Data
            if stampIsValid {
                stamp = try XCTUnwrap(LXStamper.generateStamp(
                    messageID: Hashes.fullHash(lxmfData),
                    stampCost: router.propagationStampCost))
            } else {
                // 32 bytes that are not a proof of work for this message at the node's cost.
                stamp = Data(repeating: 0x00, count: 32)
            }

            let payload = MsgPack.encode(.array([
                .double(Date().timeIntervalSince1970),
                .array([.bytes(lxmfData + stamp)]),
            ]))

            let uploaded = test.expectation(description: "resource concluded")
            let sender = ResourceTransfer(link: link)
            sender.onComplete = { _ in uploaded.fulfill() }
            try sender.send(payload: payload)
            test.wait(for: [uploaded], timeout: 5.0)

            let settled = test.expectation(description: "receiver settled")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
            test.wait(for: [settled], timeout: 2.0)
        }

        /// Offer the node a transient ID it does not have, over the same link, and return the
        /// node's answer.
        func makeOffer() throws -> MsgPack.Value {
            let offered = Hashes.fullHash(Data(UUID().uuidString.utf8))
            let request = MsgPack.Value.array([
                .bytes(Data(repeating: 0x00, count: 32)),   // peering key; peeringCost is 0
                .array([.bytes(offered)]),
            ])

            var answer: MsgPack.Value?
            let answered = test.expectation(description: "offer answered")
            _ = try link.request(path: LXMPeer.offerRequestPath, nativeValue: request,
                                 responseCallback: { data, _ in
                                     answer = try? MsgPack.decode(data)
                                     answered.fulfill()
                                 })
            test.wait(for: [answered], timeout: 5.0)
            return try XCTUnwrap(answer)
        }
    }

    private func makeNodeAndRemote() throws -> Network {
        let nodeTransport   = Transport()
        let remoteTransport = Transport()
        retained.append(contentsOf: [nodeTransport, remoteTransport])

        let router = LXMRouter(transport: nodeTransport)
        try router.register(identity: Identity(), transport: nodeTransport)
        // A cost the all-zero stamp cannot meet, so "invalid" is a real validation failure rather
        // than a malformed payload.
        router.propagationStampCost = 8
        router.peeringCost          = 0
        try router.enablePropagation(storagePath: tempDir)
        retained.append(router)

        let nodeInterface   = ThrottleLoopInterface(name: "node")
        let remoteInterface = ThrottleLoopInterface(name: "remote")
        nodeInterface.paired = remoteInterface
        remoteInterface.paired = nodeInterface
        nodeTransport.register(interface: nodeInterface)
        remoteTransport.register(interface: remoteInterface)

        let propagationDestination = try XCTUnwrap(router.propagationDestination)
        nodeTransport.register(destination: propagationDestination)

        let remoteIdentity = Identity()
        let remotePropagationHash = try Destination(identity: remoteIdentity, direction: .out,
                                                    kind: .single, appName: APP_NAME,
                                                    aspects: ["propagation"]).hash

        let localUp  = expectation(description: "remote side up")
        let remoteUp = expectation(description: "node side up")
        remoteTransport.onLinkEstablished = { _ in localUp.fulfill() }
        nodeTransport.onLinkEstablished   = { _ in remoteUp.fulfill() }
        let link = try Link.initiate(destination: propagationDestination, transport: remoteTransport)
        wait(for: [localUp, remoteUp], timeout: 3.0)

        let nodeSideLink = try XCTUnwrap(nodeTransport.links[try XCTUnwrap(link.linkID)])
        let identified = expectation(description: "node sees the remote's identity")
        nodeSideLink.onRemoteIdentified = { _, _ in identified.fulfill() }
        try link.identify(as: remoteIdentity)
        wait(for: [identified], timeout: 2.0)

        return Network(router: router, remotePropagationHash: remotePropagationHash,
                       link: link, test: self)
    }
}

// MARK: - Loopback interface

private final class ThrottleLoopInterface: Interface {
    let name: String
    var bitrate: Int = 1_000_000
    var isOnline: Bool = true
    var inboundHandler: ((Packet, any Interface) -> Void)?
    weak var paired: ThrottleLoopInterface?

    init(name: String) { self.name = name }
    func start() throws { isOnline = true }
    func stop() { isOnline = false }

    func send(_ packet: Packet) throws {
        let raw  = try packet.pack()
        let copy = try Packet.unpack(raw)
        paired?.inboundHandler?(copy, paired!)
    }
}
