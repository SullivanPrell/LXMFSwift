import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/053` — a peer's refusal is recognised as a refusal.
///
/// Every LXMF error code is above 127 (`LXMPeer.py:23-31`), so msgpack writes it as a `uint8`
/// (`0xCC`) and `MsgPack.decode` hands back `.uint` (`MsgPack.swift:212`). `processOfferResponse`
/// matched with `case .int(let code)`, which does not match a `.uint` — a `switch` tests the enum
/// case, not numeric equality — so **every** error code fell through to `default: return
/// .noneWanted`.
///
/// That reads "the peer refuses you" as "the peer wants nothing":
/// - `ERROR_THROTTLED` (0xF6) — no back-off. Python postpones the next sync by `PN_STAMP_THROTTLE`
///   (`LXMPeer.py:421-425`); we would retry at the normal cadence into a node that is refusing us.
/// - `ERROR_NO_IDENTITY` (0xF0) — no re-identify. Python identifies again and retries the sync
///   immediately (`:408-414`); we would drop the sync and offer the same messages next pass.
/// - `ERROR_NO_ACCESS` (0xF1) — no unpeer. Python breaks the peering (`:416-419`); we would keep
///   dialling a node that has told us we are not welcome.
///
/// This was unreachable while outbound sync was a stub, and became live the moment it was not,
/// which is why it is fixed alongside it rather than after.
final class OfferResponseErrorCodeTests: XCTestCase {

    /// Every code, through a real encode/decode round trip — the wire form is the whole point.
    func testEveryErrorCodeSurvivesTheWireAndIsRecognised() throws {
        let codes: [LXMPeerError] = [.noIdentity, .noAccess, .invalidKey, .invalidData,
                                     .invalidStamp, .throttled, .notFound, .timeout]

        for expected in codes {
            let onWire = MsgPack.encode(.int(Int64(expected.rawValue)))
            let decoded = try MsgPack.decode(onWire)

            let peer = try makePeer()
            let result = peer.processOfferResponse(decoded)

            guard case .error(let got) = result else {
                return XCTFail("""
                    \(expected) came back from the wire as \(decoded) and was read as \(result). \
                    A code above 127 travels as a msgpack uint8, so `case .int` never matches it \
                    and it falls through to `default: return .noneWanted` — the peer's refusal \
                    reads as "the peer wants nothing".
                    """)
            }
            XCTAssertEqual(got, expected, "the code round-tripped but decoded to the wrong error")
        }
    }

    func testAPythonEncodedThrottleIsRecognised() throws {
        // Exactly the bytes Python's msgpack produces for 0xF6: uint8 marker, then the value.
        let pythonBytes = Data([0xCC, 0xF6])
        let peer = try makePeer()

        let result = peer.processOfferResponse(try MsgPack.decode(pythonBytes))

        guard case .error(.throttled) = result else {
            return XCTFail("""
                a Python propagation node's ERROR_THROTTLED was read as \(result). Unrecognised, \
                the sync back-off never happens and we keep dialling a node that is refusing us — \
                which is what the throttle exists to stop.
                """)
        }
    }

    /// The non-error branches must be untouched: a numeric pre-check that swallowed `false`, `true`
    /// or a wanted-ID list would break the sync it is meant to protect.
    func testTheOrdinaryResponsesStillDecode() throws {
        let none = try makePeer()
        guard case .noneWanted = none.processOfferResponse(.bool(false)) else {
            return XCTFail("`false` means the peer already has everything offered")
        }

        let all = try makePeer()
        guard case .allWanted = all.processOfferResponse(.bool(true)) else {
            return XCTFail("`true` means the peer wants everything offered")
        }

        let wantedID = Data(repeating: 0x7A, count: 32)
        let some = try makePeer()
        guard case .partialWanted(let ids) = some.processOfferResponse(.array([.bytes(wantedID)]))
        else {
            return XCTFail("a list means the peer wants that subset")
        }
        XCTAssertEqual(ids, [wantedID])
    }

    func testAValueThatIsNotAnErrorCodeIsNotReadAsOne() throws {
        // 0x05 is a perfectly ordinary small integer and no LXMF error code.
        let peer = try makePeer()
        let result = peer.processOfferResponse(try MsgPack.decode(MsgPack.encode(.int(5))))

        guard case .error = result else { return }
        XCTFail("5 is not an error code; a numeric pre-check must not treat every number as one")
    }

    // MARK: - Harness

    private var retained: [AnyObject] = []
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_offererr_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        retained.removeAll()
        super.tearDown()
    }

    private func makePeer() throws -> LXMPeer {
        let transport = Transport()
        let router = LXMRouter(transport: transport)
        router.propagationStampCost = 0
        try router.register(identity: Identity(), transport: transport)
        try router.enablePropagation(storagePath: tempDir)
        retained.append(transport); retained.append(router)
        return router.addPeer(destinationHash: Data(repeating: 0xE1, count: 16))
    }
}
