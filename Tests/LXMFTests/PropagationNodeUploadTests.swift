import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/021` — the propagation node's *packet* upload path.
///
/// Python's `propagation_link_established` sets **both** a packet callback and the resource
/// callbacks (`LXMRouter.py:2189-2193`); the port wired only the resource path, so
/// `link.onDataReceived` stayed nil and ReticulumSwift's `Link` dropped the plaintext without a
/// proof. Python clients take the packet path for any message whose propagation container fits
/// `LINK_PACKET_MAX_CONTENT = 319` bytes (`LXMessage.py:439-441`) — an ordinary short chat
/// message — so a Swift node worked for long messages and lost short ones, silently.
///
/// `LXMPropagationNodeTests` drives `handleInboundPropagationResource` directly, which is the
/// resource path only; these tests put a real DATA packet on a real link, because the defect is
/// which callbacks the link *has*, and no direct call can observe that.
final class PropagationNodeTests: XCTestCase {

    private var tempDir: String!
    private var net: PeerOutboundSyncNetwork!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_pnupload_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        net = nil
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    /// A live client link from A's transport to B's propagation destination.
    private func openClientLink() throws -> Link {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 2)
        try net.announceBToA()
        let nodeIdentity = try XCTUnwrap(net.transportA.recall(identity: net.bPropagationHash))
        let nodeDest = try Destination(identity: nodeIdentity, direction: .out, kind: .single,
                                       appName: APP_NAME, aspects: ["propagation"])
        let link = try Link.initiate(destination: nodeDest, transport: net.transportA)
        XCTAssertTrue(net.waitUntil("client link up", timeout: 5) { link.status == .active },
                      "precondition: the client link must establish before anything is uploaded")
        return link
    }

    /// One propagated message in the reference's packet wire shape:
    /// `msgpack([timestamp, [lxmf_data ‖ 32-byte stamp]])` (`LXMRouter.py:2234-2246`).
    private func packetPayload(body: Data, stamp: Data = Data(repeating: 0, count: 32)) throws -> Data {
        try MsgPack.encode(.array([
            .double(Date().timeIntervalSince1970),
            .array([.bytes(body + stamp)]),
        ]))
    }

    /// A unique message body of the minimum shape the store accepts.
    private func uniqueBody(size: Int = 200) -> Data {
        var body = Data(repeating: 0x5A, count: max(size, LXMessage.destinationLength + 1))
        body.replaceSubrange(0..<8, with: UUID().uuidString.prefix(8).utf8)
        return body
    }

    // MARK: - 6.7

    func testSinglePacketUploadIsIngestedAndProved() throws {
        let link = try openClientLink()
        let body = uniqueBody()
        let transientID = Hashes.fullHash(body)

        let receipt = try XCTUnwrap(link.send(try packetPayload(body: body)),
                                    "a link data packet must produce a receipt — the proof is "
                                    + "what the client waits on")

        XCTAssertTrue(net.waitUntil("message stored", timeout: 5) {
            self.net.routerB.propagationEntries[transientID] != nil
        }, """
        the node dropped a single-packet upload: no packet callback is set at propagation link \
        establishment, so the plaintext went nowhere (`LXMRouter.py:2189` sets \
        `set_packet_callback(self.propagation_packet)`; the port wires only the resource path)
        """)

        XCTAssertTrue(net.waitUntil("packet proved", timeout: 5) {
            receipt.status == .delivered
        }, """
        no proof came back for the upload. The proof is the client's delivery confirmation — \
        without it a Python client retries to MAX_DELIVERY_ATTEMPTS and marks the message \
        FAILED (`propagation_packet` ends in `packet.prove()`, `LXMRouter.py:2251`)
        """)
    }

    /// The reject half of `propagation_packet` (`LXMRouter.py:2253-2256`): a payload whose stamps
    /// do not all validate is answered with `ERROR_INVALID_STAMP` and the link is torn down —
    /// not proved, not silently dropped.
    func testInvalidStampUploadIsRejectedNotProved() throws {
        let link = try openClientLink()
        // B now demands real work for a client upload; a zero stamp cannot satisfy it.
        net.routerB.propagationStampCost = 20
        net.routerB.propagationStampCostFlexibility = 0

        let body = uniqueBody()
        let transientID = Hashes.fullHash(body)
        let receipt = try XCTUnwrap(link.send(try packetPayload(body: body)))

        XCTAssertTrue(net.waitUntil("link torn down", timeout: 5) { link.status != .active },
                      "the reference tears the link down on an invalid-stamp upload")
        net.settle(0.2)
        XCTAssertNil(net.routerB.propagationEntries[transientID],
                     "a message with an unmet stamp cost must not enter the store")
        XCTAssertNotEqual(receipt.status, .delivered,
                          "an invalid-stamp upload must not be proved — the proof would tell "
                          + "the client the node accepted what it discarded")
    }
}
