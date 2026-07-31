import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/054`, step 2 — one decoder for peer error codes.
///
/// `bugs/053` fixed the offer-response path by adding a numeric read there. It left the *decision*
/// duplicated: `LXMRouter.isPeerError` carried its own copy of "which values are error codes" and
/// its own msgpack matching. Two implementations of the same question drift, and the last time
/// they did, every refusal a peer sent read as "the peer wants nothing".
///
/// This is the seam: one place that turns a msgpack scalar into an `LXMPeerError`, used by both
/// the client download path and the peer sync path.
final class LXMPeerErrorDecodingTests: XCTestCase {

    func testEveryPythonEncodedErrorCodeDecodes() throws {
        for vector in PythonPeeringVectors.errorCodeWireForms {
            let decoded = try MsgPack.decode(vector.wire)
            let expected = LXMPeerError(rawValue: vector.code)

            XCTAssertEqual(LXMPeerError(msgPack: decoded), expected,
                           """
                           \(vector.name) (0x\(String(vector.code, radix: 16))) arrived from \
                           Python as \(decoded) and did not decode. Every LXMF error code is \
                           above 127, so umsgpack writes all eight as uint8 — a decoder that \
                           matches only `.int` recognises none of them.
                           """)
        }
    }

    func testAHandBuiltIntIsAlsoRecognised() {
        // Swift's own encoder and Python's agree on the wire form, but a value constructed in
        // memory as `.int` must decode too — that is what this package's own handlers return.
        XCTAssertEqual(LXMPeerError(msgPack: .int(0xF6)), .throttled)
        XCTAssertEqual(LXMPeerError(msgPack: .uint(0xF6)), .throttled)
    }

    func testNonErrorValuesDecodeToNil() {
        XCTAssertNil(LXMPeerError(msgPack: .bool(false)), "false means the peer wants nothing")
        XCTAssertNil(LXMPeerError(msgPack: .bool(true)),  "true means the peer wants everything")
        XCTAssertNil(LXMPeerError(msgPack: .array([])),   "an empty wanted-list is not an error")
        XCTAssertNil(LXMPeerError(msgPack: .nil))
        XCTAssertNil(LXMPeerError(msgPack: .int(-1)),     "a negative number is not a code")
        XCTAssertNil(LXMPeerError(msgPack: .int(5)),      "5 is an ordinary integer, not a code")
        XCTAssertNil(LXMPeerError(msgPack: .uint(0xF2)),  "0xF2 is not assigned")
    }

    /// The client download path asks the same question and must get it from the same place.
    func testTheClientDownloadPathUsesTheSharedDecoder() throws {
        let transport = Transport()
        let router = LXMRouter(transport: transport)
        try router.register(identity: Identity(), transport: transport)

        for vector in PythonPeeringVectors.errorCodeWireForms
        where vector.code == 0xF0 || vector.code == 0xF1 {
            XCTAssertTrue(router.isPeerError(try MsgPack.decode(vector.wire)),
                          "\(vector.name) must be recognised on the client path too")
        }
        XCTAssertFalse(router.isPeerError(.array([])),
                       "a list of available message IDs is a normal response")
    }
}
