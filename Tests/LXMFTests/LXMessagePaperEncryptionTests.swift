import XCTest
import ReticulumSwift
@testable import LXMF

/// Confidentiality of the paper-delivery representation — `bugs/026`.
///
/// A paper message exists to cross a physical channel the sender does not control: it is
/// printed, photographed, handed over. Python encrypts the payload to the destination
/// identity before base64-encoding it, so the printed form is readable only by the
/// addressed identity:
///
///     # lxmf/LXMF/LXMessage.py:449-451
///     encrypted_data    = self.__destination.encrypt(self.packed[DESTINATION_LENGTH:])
///     self.paper_packed = self.packed[:DESTINATION_LENGTH] + encrypted_data
///     # :454-458 — raises TypeError when len(paper_packed) > PAPER_MDU
///
/// Ingestion is symmetric (`LXMRouter.py:2549-2552` → `:2503-2504`).
///
/// These assertions are the ones the pre-existing round-trip tests could not make.
/// `LXMessageURITests.testAsURIIsRoundTrippable` and `testIngestValidURIDelivers` checked
/// only that the destination hash survived a Swift→Swift round trip — which is exactly what
/// a plaintext payload permits, so they passed for the whole life of the defect.
final class LXMessagePaperEncryptionTests: XCTestCase {

    private static let TEST_APP_NAME = "lxmpaper"

    private func makeSrcDst() throws -> (Destination, Destination) {
        let src = try Destination(identity: Identity(), direction: .in, kind: .single,
                                  appName: Self.TEST_APP_NAME, aspects: ["delivery"])
        let dst = try Destination(identity: Identity(), direction: .in, kind: .single,
                                  appName: Self.TEST_APP_NAME, aspects: ["delivery"])
        return (src, dst)
    }

    /// Base64url-decode the `lxm://` payload, exactly as Python's `ingest_lxm_uri` does
    /// (`LXMRouter.py:2549`) — this is what anyone who photographs the QR obtains.
    private func decodePayload(_ uri: String) throws -> Data {
        let encoded = String(uri.dropFirst("lxm://".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padLen = (4 - encoded.count % 4) % 4
        guard let data = Data(base64Encoded: encoded + String(repeating: "=", count: padLen)) else {
            throw LXMessage.LXMessageError.invalidURI
        }
        return data
    }

    /// Deterministic incompressible filler — a SHA-256 chain rendered as hex, so a
    /// size-limit test cannot be defeated by a compressor squeezing the body away
    /// (the mechanism that made `tri-test`'s large-resource cell unfalsifiable, §6.2).
    private func incompressibleBody(byteCount: Int) -> String {
        var out = ""
        var block = Data("lxmf-026-paper".utf8)
        while out.utf8.count < byteCount {
            block = Hashes.fullHash(block)
            out += block.map { String(format: "%02x", $0) }.joined()
        }
        return String(out.prefix(byteCount))
    }

    // MARK: - The printed form must not carry the message

    func testPaperURIDoesNotCarryTheMessageInCleartext() throws {
        let (src, dst) = try makeSrcDst()
        let secretBody  = "MEET-AT-THE-BRIDGE-AT-MIDNIGHT-8F2A1C"
        let secretTitle = "SUBJECT-CONFIDENTIAL-D41B"

        let msg = LXMessage(destination: dst, source: src,
                            content: secretBody, title: secretTitle,
                            desiredMethod: .paper)
        try msg.pack()
        let payload = try decodePayload(try msg.asURI())

        // The destination hash is public by design — it is how the message is addressed.
        XCTAssertEqual(Data(payload.prefix(LXMessage.destinationLength)), msg.destinationHash,
                       "the first 16 bytes must remain the plaintext destination hash")

        // Everything after it is encrypted to the destination identity.
        XCTAssertNil(payload.range(of: Data(secretBody.utf8)),
                     "the message body appears in cleartext in the paper payload")
        XCTAssertNil(payload.range(of: Data(secretTitle.utf8)),
                     "the message title appears in cleartext in the paper payload")
        XCTAssertNil(Data(payload.dropFirst(LXMessage.destinationLength)).range(of: msg.sourceHash),
                     "the sender's hash appears in cleartext in the paper payload")
    }

    func testPaperPayloadIsNotThePlaintextWireForm() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "not the wire bytes", desiredMethod: .paper)
        try msg.pack()
        let payload = try decodePayload(try msg.asURI())
        guard let wire = msg.packed else { return XCTFail("pack() did not set packed") }

        XCTAssertNotEqual(payload, wire,
                          "asURI() base64-encodes the plaintext wire bytes rather than the encrypted paper form")
        XCTAssertNotEqual(Data(payload.dropFirst(LXMessage.destinationLength)),
                          Data(wire.dropFirst(LXMessage.destinationLength)),
                          "the payload after the destination hash must be ciphertext, not the wire payload")
    }

    // MARK: - Recovery requires the addressed identity's private key

    func testAnUnrelatedIdentityCannotRecoverTheContent() throws {
        let (src, dst) = try makeSrcDst()
        let secretBody = "ONLY-THE-ADDRESSEE-MAY-READ-THIS-77C3"
        let msg = LXMessage(destination: dst, source: src,
                            content: secretBody, desiredMethod: .paper)
        try msg.pack()
        let payload = try decodePayload(try msg.asURI())

        // An eavesdropper holding some other identity gets nothing back.
        let stranger = try Destination(identity: Identity(), direction: .in, kind: .single,
                                       appName: Self.TEST_APP_NAME, aspects: ["delivery"])
        let recovered = try? stranger.decrypt(Data(payload.dropFirst(LXMessage.destinationLength)))
        XCTAssertNil(recovered,
                     "an unrelated identity must not be able to decrypt the paper payload")

        // Nor by simply reading the blob as a wire-format LXM.
        if let asWire = try? LXMessage.unpack(payload) {
            XCTAssertNotEqual(asWire.content, Data(secretBody.utf8),
                              "the paper payload decoded as plain wire bytes yielded the message content")
        }
    }

    // MARK: - PAPER_MDU is enforced at creation

    func testOversizedPaperMessageThrowsAtPack() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: incompressibleBody(byteCount: LXMessage.paperMDU + 1024),
                            desiredMethod: .paper)
        // Python raises TypeError inside pack() (`LXMessage.py:457-458`) rather than
        // handing back a URI that silently will not fit in a QR code.
        XCTAssertThrowsError(try msg.pack(),
                             "pack() must reject a paper message whose payload exceeds PAPER_MDU")
    }

    func testPaperMessageAtTheLimitStillPacks() throws {
        let (src, dst) = try makeSrcDst()
        // Comfortably inside PAPER_MDU once encryption overhead is added.
        let msg = LXMessage(destination: dst, source: src,
                            content: incompressibleBody(byteCount: 1024),
                            desiredMethod: .paper)
        XCTAssertNoThrow(try msg.pack(),
                         "a paper message inside PAPER_MDU must pack")
        let payload = try decodePayload(try msg.asURI())
        XCTAssertLessThanOrEqual(payload.count, LXMessage.paperMDU,
                                 "a packed paper payload must fit PAPER_MDU")
    }

    // MARK: - The paper route gets the same inbound handling as every other route

    func testIngestedPaperMessageFromIgnoredSenderIsNotDelivered() throws {
        let transport = Transport()
        let router = LXMRouter(transport: transport)
        let recipientID = Identity()
        let delivery = try router.register(identity: recipientID, transport: transport)

        let src = try Destination(identity: Identity(), direction: .in, kind: .single,
                                  appName: LXMF.APP_NAME, aspects: ["delivery"])
        let msg = LXMessage(destination: delivery, source: src,
                            content: "from an ignored sender", desiredMethod: .paper)
        try msg.pack()
        let uri = try msg.asURI()

        // Python applies the ignore list to every inbound route, paper included:
        // ingest_lxm_uri → lxmf_propagation → lxmf_delivery (`LXMRouter.py:2552`, `:2506`).
        router.ignoreDestination(destinationHash: src.hash)

        var delivered: LXMessage? = nil
        router.onMessageReceived = { delivered = $0 }
        try router.ingestLXMURI(uri)

        XCTAssertNil(delivered,
                     "a paper message from an ignored sender must not be delivered — ingestLXMURI bypasses the ignore list")
    }

    func testIngestedPaperMessageIsSuppressedAsADuplicate() throws {
        let transport = Transport()
        let router = LXMRouter(transport: transport)
        let delivery = try router.register(identity: Identity(), transport: transport)

        let src = try Destination(identity: Identity(), direction: .in, kind: .single,
                                  appName: LXMF.APP_NAME, aspects: ["delivery"])
        let msg = LXMessage(destination: delivery, source: src,
                            content: "scanned twice", desiredMethod: .paper)
        try msg.pack()
        let uri = try msg.asURI()

        var deliveries = 0
        router.onMessageReceived = { _ in deliveries += 1 }
        try router.ingestLXMURI(uri)
        try? router.ingestLXMURI(uri)

        XCTAssertEqual(deliveries, 1,
                       "re-scanning the same paper message must be suppressed as a duplicate")
    }
}
