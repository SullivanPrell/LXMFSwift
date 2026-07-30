import XCTest
import ReticulumSwift
@testable import LXMF

/// Tests for LXMessage.asURI() and LXMRouter.ingestLXMURI().
///
/// Python reference (LXMessage.py):
///   LXMessage.URI_SCHEMA = "lxm"
///   message.as_uri() → "lxm://<base64url-no-padding>" for paper method
///   message.as_uri() raises TypeError for non-paper messages
///   LXMRouter.ingest_lxm_uri(uri) → delivers decoded message
final class LXMessageURITests: XCTestCase {

    private func makeSrcDst() throws -> (Destination, Destination) {
        let srcID = Identity(); let dstID = Identity()
        let src = try Destination(identity: srcID, direction: .in, kind: .single, appName: APP_NAME, aspects: ["delivery"])
        let dst = try Destination(identity: dstID, direction: .in, kind: .single, appName: APP_NAME, aspects: ["delivery"])
        return (src, dst)
    }

    // MARK: - URI_SCHEMA constant

    func testURISchemaIsLxm() {
        XCTAssertEqual(LXMessage.uriSchema, "lxm",
                       "URI_SCHEMA must be 'lxm'")
    }

    // MARK: - asURI() for paper messages

    func testAsURIReturnsPaperURI() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "hello uri", desiredMethod: .paper)
        try msg.pack()
        let uri = try msg.asURI()
        XCTAssertTrue(uri.hasPrefix("lxm://"), "asURI() must start with 'lxm://'")
    }

    func testAsURIIsURLSafeBase64() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "base64 test", desiredMethod: .paper)
        try msg.pack()
        let uri = try msg.asURI()
        let encoded = String(uri.dropFirst("lxm://".count))
        // URL-safe base64 uses - and _ (not + and /)
        XCTAssertFalse(encoded.contains("+"), "URI must use URL-safe base64 (no '+')")
        XCTAssertFalse(encoded.contains("/"), "URI must use URL-safe base64 (no '/')")
        XCTAssertFalse(encoded.contains("="), "URI must have no padding '='")
    }

    func testAsURIThrowsForNonPaperMessage() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "direct msg", desiredMethod: .direct)
        try msg.pack()
        XCTAssertThrowsError(try msg.asURI(),
                             "asURI() must throw for non-paper delivery method")
    }

    /// Rebuilt for `bugs/026`. The previous version decoded the URI and asserted only that
    /// the destination hash survived — which a plaintext payload satisfies just as well as
    /// an encrypted one, so it could not fail while the payload was cleartext. A round trip
    /// is only evidence if it carries the *content* through the decryption step.
    func testAsURIRoundTripsThroughTheDestinationKey() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "round trip", title: "subject line",
                            desiredMethod: .paper)
        try msg.pack()
        let uri = try msg.asURI()

        let decoded = try LXMessage.fromURI(uri, destination: dst)
        XCTAssertEqual(decoded.destinationHash, msg.destinationHash,
                       "decoded message must have the same destination hash")
        XCTAssertEqual(decoded.sourceHash, msg.sourceHash,
                       "decoded message must carry the sender hash through decryption")
        XCTAssertEqual(decoded.contentAsString, "round trip",
                       "the content must survive the encrypt/decrypt round trip")
        XCTAssertEqual(decoded.titleAsString, "subject line",
                       "the title must survive the encrypt/decrypt round trip")
    }

    func testFromURIFailsWithoutTheAddressedKey() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "not for you", desiredMethod: .paper)
        try msg.pack()
        let uri = try msg.asURI()

        let stranger = try Destination(identity: Identity(), direction: .in, kind: .single,
                                       appName: APP_NAME, aspects: ["delivery"])
        XCTAssertThrowsError(try LXMessage.fromURI(uri, destination: stranger),
                            "decoding must fail without the addressed identity's private key")
    }

    // MARK: - LXMRouter.ingestLXMURI()

    /// Rebuilt for `bugs/026`. The previous version built the router with no registered
    /// delivery destination and asserted the destination hash of whatever came back — which
    /// the old plaintext path could satisfy without ever decrypting anything. Ingesting a
    /// paper message now requires the router to host the addressed destination and hold its
    /// private key, and the assertion is on the recovered content.
    func testIngestValidURIDelivers() throws {
        let transport = Transport()
        let router = LXMRouter(transport: transport)
        let delivery = try router.register(identity: Identity(), transport: transport)

        let src = try Destination(identity: Identity(), direction: .in, kind: .single,
                                  appName: APP_NAME, aspects: ["delivery"])
        let msg = LXMessage(destination: delivery, source: src,
                            content: "ingest test", desiredMethod: .paper)
        try msg.pack()
        let uri = try msg.asURI()

        var delivered: LXMessage? = nil
        router.onMessageReceived = { delivered = $0 }
        XCTAssertTrue(try router.ingestLXMURI(uri),
                      "ingestLXMURI must report the message as delivered")

        XCTAssertNotNil(delivered, "ingestLXMURI must deliver the decoded message")
        XCTAssertEqual(delivered?.destinationHash, msg.destinationHash)
        XCTAssertEqual(delivered?.contentAsString, "ingest test",
                       "the delivered message must carry the decrypted content")
    }

    func testIngestURIAddressedElsewhereThrows() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "someone else's mail", desiredMethod: .paper)
        try msg.pack()
        let uri = try msg.asURI()

        // A router hosting no matching delivery destination cannot read it, and must say so
        // rather than reporting an ingest it did not perform.
        let router = LXMRouter(transport: Transport())
        var delivered: LXMessage? = nil
        router.onMessageReceived = { delivered = $0 }
        XCTAssertThrowsError(try router.ingestLXMURI(uri))
        XCTAssertNil(delivered, "a paper message addressed elsewhere must not be delivered")
    }

    func testIngestMalformedURIThrows() {
        let router = LXMRouter(transport: Transport())
        XCTAssertThrowsError(try router.ingestLXMURI("not-a-uri"),
                             "ingestLXMURI must throw for malformed URI")
    }

    func testIngestWrongSchemeThrows() {
        let router = LXMRouter(transport: Transport())
        XCTAssertThrowsError(try router.ingestLXMURI("http://example.com"),
                             "ingestLXMURI must throw for wrong URI scheme")
    }
}
