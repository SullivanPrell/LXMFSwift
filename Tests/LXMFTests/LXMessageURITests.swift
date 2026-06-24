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

    func testAsURIIsRoundTrippable() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "round trip", desiredMethod: .paper)
        try msg.pack()
        let uri = try msg.asURI()

        // Decode back and verify destination hash matches
        let decoded = try LXMessage.fromURI(uri)
        XCTAssertEqual(decoded.destinationHash, msg.destinationHash,
                       "decoded message must have the same destination hash")
    }

    // MARK: - LXMRouter.ingestLXMURI()

    func testIngestValidURIDelivers() throws {
        let (src, dst) = try makeSrcDst()
        let router = LXMRouter(transport: Transport())

        let msg = LXMessage(destination: dst, source: src,
                            content: "ingest test", desiredMethod: .paper)
        try msg.pack()
        let uri = try msg.asURI()

        var delivered: LXMessage? = nil
        router.onMessageReceived = { delivered = $0 }
        try router.ingestLXMURI(uri)

        XCTAssertNotNil(delivered, "ingestLXMURI must deliver the decoded message")
        XCTAssertEqual(delivered?.destinationHash, msg.destinationHash)
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
