import XCTest
import LXMF
import ReticulumSwift

/// Tests for LXMF Resource delivery — large messages (> 319 bytes content) sent as Resources over links.
final class LXMRouterResourceTests: XCTestCase {

    // 319 = Link.mdu (464) - lxmfOverhead (145). Content at this boundary or below uses .packet.
    static let linkPacketMaxContent = 319

    // MARK: - Representation selection

    func testSmallMessageSelectsPacketRepresentation() throws {
        let (src, dst, _, _) = try makeDeliveryPair()
        let msg = LXMessage(destination: dst, source: src, content: "short")
        try msg.pack()
        XCTAssertEqual(msg.representation, .packet)
    }

    func testLargeMessageSelectsResourceRepresentation() throws {
        let (src, dst, _, _) = try makeDeliveryPair()
        let bigContent = String(repeating: "X", count: Self.linkPacketMaxContent + 1)
        let msg = LXMessage(destination: dst, source: src, content: bigContent)
        try msg.pack()
        XCTAssertEqual(msg.representation, .resource)
    }

    func testExactlyAtLimitUsesPacket() throws {
        let (src, dst, _, _) = try makeDeliveryPair()
        // Content at exactly linkPacketMaxContent — should still be .packet.
        let exactContent = String(repeating: "Y", count: Self.linkPacketMaxContent)
        let msg = LXMessage(destination: dst, source: src, content: exactContent)
        try msg.pack()
        XCTAssertEqual(msg.representation, .packet)
    }

    // MARK: - Resource round-trip over a link

    func testLargeMessageResourceRoundTrip() throws {
        let (aTransport, bTransport, aLink, bLink) = try establishLoopbackLinks()
        defer { _ = (aTransport, bTransport) }

        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let bigContent = String(repeating: "Z", count: Self.linkPacketMaxContent + 1)
        let msg = LXMessage(destination: dst, source: src, content: bigContent)
        try msg.pack()
        XCTAssertEqual(msg.representation, .resource)

        // Resource carries the FULL packed bytes (including dest hash) — matches Python LXMessage.__as_resource().
        let packed = msg.packed!

        // Receiver: bind ResourceTransfer on B side, collect assembled payload.
        var receivedData: Data?
        let receiveExp = expectation(description: "resource received on B")
        let receiver = ResourceTransfer(link: bLink)
        receiver.onPayloadReceived = { data, _ in
            receivedData = data
            receiveExp.fulfill()
        }
        receiver.bindAsReceiver()

        // Sender: advertise resource from A side with FULL packed bytes.
        var senderComplete = false
        let sendExp = expectation(description: "sender completes")
        let sender = ResourceTransfer(link: aLink)
        sender.onComplete = { _ in
            senderComplete = true
            sendExp.fulfill()
        }
        try sender.send(payload: packed)

        wait(for: [receiveExp, sendExp], timeout: 3.0)

        XCTAssertTrue(senderComplete)
        XCTAssertNotNil(receivedData)

        // Resource data IS the full packed LXMessage bytes — decode directly.
        let decoded = try LXMessage.unpack(receivedData!)
        XCTAssertEqual(decoded.contentAsString, bigContent)
        XCTAssertEqual(decoded.destinationHash, dst.hash)
        XCTAssertEqual(decoded.sourceHash, src.hash)
    }

    // MARK: - LXMRouter large message delivery

    func testRouterDeliversLargeMessageViaDirectLink() throws {
        let (aTransport, bTransport, aLink, bLink) = try establishLoopbackLinks()
        defer { _ = (aTransport, bTransport) }

        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let bigContent = String(repeating: "R", count: Self.linkPacketMaxContent + 10)
        let msg = LXMessage(destination: dst, source: src, content: bigContent)
        try msg.pack()
        XCTAssertEqual(msg.representation, .resource)

        // Receiver side: accept incoming resources on bLink.
        var receivedPayload: Data?
        let receiveExp = expectation(description: "resource received on B")
        bLink.resourceStrategy = .acceptAll
        bLink.onResourceConcluded = { data, _, _ in
            receivedPayload = data
            receiveExp.fulfill()
        }

        // Sender side: resource carries FULL packed bytes (mirrors what LXMRouter.sendOverLink will do).
        let body = msg.packed!
        let sender = ResourceTransfer(link: aLink)
        var delivered = false
        let deliverExp = expectation(description: "sender delivered")
        sender.onComplete = { _ in
            delivered = true
            deliverExp.fulfill()
        }
        try sender.send(payload: body)

        wait(for: [receiveExp, deliverExp], timeout: 3.0)
        XCTAssertTrue(delivered)
        XCTAssertNotNil(receivedPayload)
        _ = (aLink, bLink) // keep alive
    }

    // MARK: - LXMRouter direct link delivery (small + large messages)

    func testRouterReceivesSmallMessageOnDeliveryLink() throws {
        let (aTransport, bTransport, aLink, _) = try establishLoopbackLinks()
        defer { _ = (aTransport, bTransport) }

        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let smallContent = "Hi there!"  // well under 319 bytes
        let msg = LXMessage(destination: dst, source: src, content: smallContent)
        try msg.pack()
        XCTAssertEqual(msg.representation, .packet)

        // Receiver side: register a delivery destination; its onLinkEstablished should
        // install onDataReceived to decode inbound small messages.
        let receiverRouter = LXMRouter(transport: bTransport)
        try receiverRouter.register(identity: dstId, transport: bTransport)

        // Pre-load the sender's identity into bTransport so signature validation
        // completes immediately (no deferred-announce wait needed for unit tests
        // where the source never sends an announce over the wire).
        bTransport.restore(identity: srcId, forDestination: src.hash)

        var receivedMsg: LXMessage?
        let receiveExp = expectation(description: "small message received on link")
        receiverRouter.onMessageReceived = { msg in
            receivedMsg = msg
            receiveExp.fulfill()
        }

        // Get the B-side link (responder) and configure its data handler by
        // simulating the onLinkEstablished callback on the delivery destination.
        let bLink = try XCTUnwrap(bTransport.links[aLink.linkID!])
        // Manually trigger onLinkEstablished since it's set AFTER the link arrived.
        bTransport.registeredDestinations[dst.hash]?.onLinkEstablished?(bLink)

        // Sender side: send the FULL packed message over the link.
        // Python DIRECT delivery (link-based) sends self.packed in full — the destination
        // hash is NOT stripped, so the receiver must NOT prepend it again.
        // (OPPORTUNISTIC delivery strips the dest hash; DIRECT link delivery does not.)
        let body = msg.packed!
        try aLink.send(body)

        wait(for: [receiveExp], timeout: 1.0)
        XCTAssertNotNil(receivedMsg)
        XCTAssertEqual(receivedMsg?.contentAsString, smallContent)
    }

    // MARK: - LXMRouter.send small message end-to-end (direct link packet)

    func testRouterSendsAndReceivesSmallMessageViaDirectLink() throws {
        let (aTransport, bTransport, aLink, bLink) = try establishLoopbackLinks()
        defer { _ = (aTransport, bTransport) }

        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let smallContent = "hello direct"  // well under 319 bytes

        // Receiver side: LXMRouter registered on B, accepting delivery to dst.
        let receiverRouter = LXMRouter(transport: bTransport)
        try receiverRouter.register(identity: dstId, transport: bTransport)

        // Pre-load the sender's identity so signature validation completes immediately.
        bTransport.restore(identity: srcId, forDestination: src.hash)

        var receivedMsg: LXMessage?
        let receiveExp = expectation(description: "small message received by router")
        receiverRouter.onMessageReceived = { msg in
            receivedMsg = msg
            receiveExp.fulfill()
        }

        // Wire bLink to the delivery destination's handler (mirrors what onLinkEstablished does).
        bTransport.registeredDestinations[dst.hash]?.onLinkEstablished?(bLink)

        // Sender side: LXMRouter on A sends a small message.
        let senderRouter = LXMRouter(transport: aTransport)
        let msg = LXMessage(destination: dst, source: src, content: smallContent, desiredMethod: .direct)
        try msg.pack()
        XCTAssertEqual(msg.representation, .packet, "short message should use packet representation")

        // Inject the established link so sendOverLink fires immediately.
        senderRouter.injectDirectLink(aLink, for: dst.hash)

        var deliveredMsg: LXMessage?
        let deliverExp = expectation(description: "sender marks delivered")
        msg.onDelivery = { m in
            deliveredMsg = m
            deliverExp.fulfill()
        }
        try senderRouter.send(msg)

        wait(for: [receiveExp, deliverExp], timeout: 2.0)
        XCTAssertNotNil(deliveredMsg)
        XCTAssertNotNil(receivedMsg)
        XCTAssertEqual(receivedMsg?.contentAsString, smallContent)
        XCTAssertEqual(receivedMsg?.destinationHash, dst.hash)
        _ = (aLink, bLink)
    }

    // MARK: - LXMRouter.send large message end-to-end

    func testRouterSendsAndReceivesLargeMessageViaResource() throws {
        let (aTransport, bTransport, aLink, bLink) = try establishLoopbackLinks()
        defer { _ = (aTransport, bTransport) }

        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let bigContent = String(repeating: "E", count: Self.linkPacketMaxContent + 50)

        // Receiver side: LXMRouter registered on B, accepting delivery to dst.
        let receiverRouter = LXMRouter(transport: bTransport)
        try receiverRouter.register(identity: dstId, transport: bTransport)

        // Pre-load the sender's identity into bTransport so signature validation
        // completes immediately (no deferred-announce wait needed in unit tests).
        bTransport.restore(identity: srcId, forDestination: src.hash)

        var receivedMsg: LXMessage?
        let receiveExp = expectation(description: "large message received by router")
        receiverRouter.onMessageReceived = { msg in
            receivedMsg = msg
            receiveExp.fulfill()
        }

        // Configure bLink to accept resources (as register() should do for delivery links).
        bLink.resourceStrategy = .acceptAll
        bLink.onResourceConcluded = { [weak receiverRouter] data, _, _ in
            receiverRouter?.deliverInboundResource(data)
        }

        // Sender side: LXMRouter on A sends a large message.
        let senderRouter = LXMRouter(transport: aTransport)
        let msg = LXMessage(destination: dst, source: src, content: bigContent, desiredMethod: .direct)
        try msg.pack()
        XCTAssertEqual(msg.representation, .resource)

        // Inject the established link into the sender router so it sends immediately.
        senderRouter.injectDirectLink(aLink, for: dst.hash)

        var deliveredMsg: LXMessage?
        let deliverExp = expectation(description: "sender marks delivered")
        msg.onDelivery = { m in
            deliveredMsg = m
            deliverExp.fulfill()
        }
        try senderRouter.send(msg)

        wait(for: [receiveExp, deliverExp], timeout: 3.0)
        XCTAssertNotNil(deliveredMsg)
        XCTAssertNotNil(receivedMsg)
        XCTAssertEqual(receivedMsg?.contentAsString, bigContent)
        _ = (aLink, bLink)
    }
}

// MARK: - Helpers

extension LXMRouterResourceTests {

    private func makeDeliveryPair() throws -> (src: Destination, dst: Destination, srcId: Identity, dstId: Identity) {
        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        return (src, dst, srcId, dstId)
    }

    /// Establish a fully-active loopback link pair (A initiates to B).
    /// Returns (aTransport, bTransport, aLink, bLink).
    private func establishLoopbackLinks() throws -> (Transport, Transport, Link, Link) {
        let aTransport = Transport()
        let bTransport = Transport()

        let bIdentity = Identity()
        let bDest = try Destination(identity: bIdentity, direction: .in, kind: .single,
                                    appName: "lxmf", aspects: ["delivery"])
        bTransport.ownerIdentity = bIdentity
        bTransport.register(destination: bDest)

        let aIface = LoopbackIface(name: "A")
        let bIface = LoopbackIface(name: "B")
        aIface.paired = bIface
        bIface.paired = aIface
        aTransport.register(interface: aIface)
        bTransport.register(interface: bIface)

        let aEst = expectation(description: "a established")
        let bEst = expectation(description: "b established")
        aTransport.onLinkEstablished = { _ in aEst.fulfill() }
        bTransport.onLinkEstablished = { _ in bEst.fulfill() }

        let aLink = try Link.initiate(destination: bDest, transport: aTransport)
        wait(for: [aEst, bEst], timeout: 2.0)
        let bLink = try XCTUnwrap(bTransport.links[aLink.linkID!])
        return (aTransport, bTransport, aLink, bLink)
    }
}

// MARK: - Loopback interface

private final class LoopbackIface: Interface {
    let name: String
    var bitrate: Int = 1_000_000
    var isOnline: Bool = true
    var inboundHandler: ((Packet, any Interface) -> Void)?
    weak var paired: LoopbackIface?

    init(name: String) { self.name = name }

    func send(_ packet: Packet) throws {
        let raw = try packet.pack()
        let copy = try Packet.unpack(raw)
        paired?.inboundHandler?(copy, paired!)
    }
    func start() throws {}
    func stop() {}
}
