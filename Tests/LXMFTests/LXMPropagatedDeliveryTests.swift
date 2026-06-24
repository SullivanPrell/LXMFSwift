import XCTest
import LXMF
import ReticulumSwift

/// Tests for LXMF propagated delivery (client sending to a propagation node).
/// Wire-compatible with Python's `LXMessage.propagation_packed` format:
///   msgpack([timestamp_f64, [lxmf_bytes]])
final class LXMPropagatedDeliveryTests: XCTestCase {

    // MARK: - propagationPacked wire format

    func testPropagationPackedIsValidMsgpack() throws {
        let (src, dst, _, _) = try makeDeliveryPair()
        let msg = LXMessage(destination: dst, source: src, content: "propagate me!")
        try msg.pack()
        let pp = try XCTUnwrap(msg.propagationPacked, "propagationPacked should be set after pack()")
        // Should decode to [float, [bytes]] — outer array with timestamp and inner array of messages.
        guard case .array(let outer) = try MsgPack.decode(pp),
              outer.count == 2 else {
            XCTFail("propagationPacked should decode to a 2-element array")
            return
        }
        // First element: float timestamp
        if case .double(let ts) = outer[0] {
            XCTAssertGreaterThan(ts, 0)
        } else {
            XCTFail("first element should be a double timestamp, got \(outer[0])")
        }
        // Second element: array of message byte arrays
        guard case .array(let messages) = outer[1] else {
            XCTFail("second element should be an array of message bytes")
            return
        }
        XCTAssertEqual(messages.count, 1, "one message per transfer for non-peer clients")
        guard case .bytes(let msgBytes) = messages[0] else {
            XCTFail("message should be bytes")
            return
        }
        // Inner bytes are: destHash (16) + encrypt(payload) [+ optional stamp].
        // NOT the plaintext packed bytes.
        let destLen = LXMessage.destinationLength
        XCTAssertGreaterThanOrEqual(msgBytes.count, destLen, "inner bytes must include dest hash")
        XCTAssertEqual(Data(msgBytes.prefix(destLen)), msg.destinationHash,
                       "first 16 bytes must be the destination hash")
        // The encrypted region is larger than the plaintext (due to ECIES overhead).
        let packed = msg.packed!
        XCTAssertGreaterThan(msgBytes.count, packed.count - destLen,
                             "encrypted payload must be larger than original plaintext payload")
    }

    func testPropagationPackedIsEncryptedNotPlaintext() throws {
        let (src, dst, _, dstId) = try makeDeliveryPair()
        let msg = LXMessage(destination: dst, source: src, content: "store this")
        try msg.pack()
        guard let pp = msg.propagationPacked, let packed = msg.packed else {
            XCTFail("propagationPacked and packed must be non-nil after pack()")
            return
        }
        XCTAssertTrue(pp.count > packed.count, "propagation wrapper should be larger than raw message")
        guard case .array(let outer) = try? MsgPack.decode(pp),
              case .array(let msgs) = outer[1],
              case .bytes(let lxmfData) = msgs[0] else { XCTFail(); return }
        // Verify: dest hash is correct
        let destLen = LXMessage.destinationLength
        XCTAssertEqual(Data(lxmfData.prefix(destLen)), dst.hash)
        // Verify: can decrypt the encrypted payload with the destination identity
        let encPayload = Data(lxmfData.dropFirst(destLen))
        let decrypted = try dstId.decrypt(encPayload)
        // Decrypted payload = srcHash (16) + sig (64) + msgpack_payload
        XCTAssertEqual(Data(decrypted.prefix(destLen)), src.hash,
                       "first 16 decrypted bytes should be the source hash")
    }

    // MARK: - LXMRouter propagated delivery state

    func testRouterOutboundPropagationNodeNilByDefault() {
        let router = LXMRouter(transport: Transport())
        XCTAssertNil(router.outboundPropagationNode)
    }

    /// LXMF 0.9.9 (189f523): sending a propagated message with no configured
    /// outbound propagation node now throws an IOError immediately rather than
    /// silently failing. Verify the throw, the message state, and no callback.
    func testRouterFailsImmediatelyIfNoPropagationNode() throws {
        let (src, dst, _, _) = try makeDeliveryPair()
        let router = LXMRouter(transport: Transport())
        // No outbound propagation node set.
        let msg = LXMessage(destination: dst, source: src, content: "test", desiredMethod: .propagated)
        try msg.pack()
        XCTAssertNil(router.outboundPropagationNode)

        var onFailedCalled = false
        msg.onFailed = { _ in onFailedCalled = true }

        // send() must throw LXMRouterError.noPropagationNode (LXMF 0.9.9).
        XCTAssertThrowsError(try router.send(msg)) { error in
            XCTAssertEqual(error as? LXMRouterError, .noPropagationNode,
                           "must throw noPropagationNode when no propagation node is set")
        }
        XCTAssertEqual(msg.state, .failed, "message state must be .failed after the throw")
        // onFailed is not called by the new guard path (Python raises before calling fail_message callbacks).
        XCTAssertFalse(onFailedCalled, "onFailed callback is not fired by the throw guard path")
    }

    // MARK: - Propagation node link and delivery

    func testRouterSendsPropagationResourceToNode() throws {
        let (aTransport, bTransport, aLink, bLink) = try establishLoopbackLinks()
        defer { _ = (aTransport, bTransport) }

        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let msg = LXMessage(destination: dst, source: src, content: "store and forward", desiredMethod: .propagated)
        try msg.pack()
        XCTAssertNotNil(msg.propagationPacked)

        // Simulate the propagation node on the B side — accept resources.
        var receivedPropagation: Data?
        let receiveExp = expectation(description: "propagation resource received")
        bLink.resourceStrategy = .acceptAll
        bLink.onResourceConcluded = { data, _, _ in
            receivedPropagation = data
            receiveExp.fulfill()
        }

        // Send propagation_packed as a Resource from A to B (simulating what LXMRouter does).
        let pp = msg.propagationPacked!
        let sender = ResourceTransfer(link: aLink)
        try sender.send(payload: pp)

        wait(for: [receiveExp], timeout: 3.0)

        // The propagation node should receive valid msgpack: [timestamp, [lxmf_bytes]].
        XCTAssertNotNil(receivedPropagation)
        guard let pp2 = receivedPropagation,
              case .array(let outer) = try? MsgPack.decode(pp2),
              outer.count == 2,
              case .array(let msgs) = outer[1],
              case .bytes(let inner) = msgs[0] else {
            XCTFail("received data should be valid propagation msgpack")
            return
        }
        // Inner bytes are: destHash (16) + encrypt(payload) — NOT plaintext packed.
        let destLen = LXMessage.destinationLength
        XCTAssertGreaterThanOrEqual(inner.count, destLen, "inner bytes must be at least destHash length")
        XCTAssertEqual(Data(inner.prefix(destLen)), dst.hash, "first 16 bytes must be destination hash")
        // Encrypted payload is larger than plaintext due to ECIES overhead.
        XCTAssertGreaterThan(inner.count, destLen, "there must be encrypted payload after dest hash")
        _ = (aLink, bLink)
    }
}

// MARK: - Helpers

extension LXMPropagatedDeliveryTests {

    private func makeDeliveryPair() throws -> (src: Destination, dst: Destination, srcId: Identity, dstId: Identity) {
        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        return (src, dst, srcId, dstId)
    }

    private func establishLoopbackLinks() throws -> (Transport, Transport, Link, Link) {
        let aT = Transport(); let bT = Transport()
        let bId = Identity()
        let bDest = try Destination(identity: bId, direction: .in, kind: .single, appName: "lxmf", aspects: ["propagation"])
        bT.ownerIdentity = bId
        bT.register(destination: bDest)

        let aI = LoopIface(name: "A"); let bI = LoopIface(name: "B")
        aI.paired = bI; bI.paired = aI
        aT.register(interface: aI); bT.register(interface: bI)

        let aE = expectation(description: "a"); let bE = expectation(description: "b")
        aT.onLinkEstablished = { _ in aE.fulfill() }
        bT.onLinkEstablished = { _ in bE.fulfill() }
        let aLink = try Link.initiate(destination: bDest, transport: aT)
        wait(for: [aE, bE], timeout: 2.0)
        let bLink = try XCTUnwrap(bT.links[aLink.linkID!])
        return (aT, bT, aLink, bLink)
    }
}

private final class LoopIface: Interface {
    let name: String
    var bitrate: Int = 1_000_000
    var isOnline: Bool = true
    var inboundHandler: ((Packet, any Interface) -> Void)?
    weak var paired: LoopIface?
    init(name: String) { self.name = name }
    func send(_ packet: Packet) throws {
        let raw = try packet.pack()
        let copy = try Packet.unpack(raw)
        paired?.inboundHandler?(copy, paired!)
    }
    func start() throws {}
    func stop() {}
}
