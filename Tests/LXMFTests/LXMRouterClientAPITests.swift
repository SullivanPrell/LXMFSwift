import XCTest
import Foundation
import LXMF
import ReticulumSwift

/// Tests for the LXMRouter client-side API methods added for parity with
/// Python's LXMRouter (LXMF 0.9.9):
///   - getAnnounceAppData(destinationHash:)
///   - announce(destinationHash:attachedInterface:)
///   - deliveryLinkAvailable(destinationHash:)
///   - getOutboundPropagationCost()
final class LXMRouterClientAPITests: XCTestCase {

    // MARK: - Helpers

    private func makeRouter() -> (LXMRouter, Transport) {
        let t = Transport()
        let r = LXMRouter(transport: t)
        return (r, t)
    }

    private func makeIdentityAndRegister(router: LXMRouter, transport: Transport,
                                         displayName: String? = nil,
                                         stampCost: Int? = nil) throws -> (Identity, Destination) {
        let identity = Identity()
        let dest = try router.register(identity: identity,
                                       transport: transport,
                                       displayName: displayName)
        if let cost = stampCost {
            _ = router.setInboundStampCost(destinationHash: dest.hash, stampCost: cost)
        }
        return (identity, dest)
    }

    // MARK: - getAnnounceAppData

    /// Returns nil for an unregistered destination.
    func testGetAnnounceAppDataNilForUnknown() throws {
        let (router, _) = makeRouter()
        let unknown = Data(repeating: 0xAB, count: 16)
        XCTAssertNil(router.getAnnounceAppData(destinationHash: unknown),
                     "Should return nil for unknown destination")
    }

    /// Returns non-nil msgpack bytes for a registered destination.
    func testGetAnnounceAppDataNonNilForRegistered() throws {
        let (router, transport) = makeRouter()
        let (_, dest) = try makeIdentityAndRegister(router: router, transport: transport)
        XCTAssertNotNil(router.getAnnounceAppData(destinationHash: dest.hash),
                        "Should return data for registered destination")
    }

    /// Without display name or stamp cost the packed array is [nil, nil, [SF_COMPRESSION]].
    func testGetAnnounceAppDataNilFields() throws {
        let (router, transport) = makeRouter()
        let (_, dest) = try makeIdentityAndRegister(router: router, transport: transport)

        guard let appData = router.getAnnounceAppData(destinationHash: dest.hash) else {
            XCTFail("Expected non-nil appData"); return
        }
        guard case .array(let items) = (try? MsgPack.decode(appData)),
              items.count == 3 else {
            XCTFail("Expected 3-element array from msgpack"); return
        }
        XCTAssertEqual(items[0], .nil, "display_name should be nil when not set")
        XCTAssertEqual(items[1], .nil, "stamp_cost should be nil when not set")
        // items[2] should be supported_functionality = [SF_COMPRESSION]
        guard case .array(let funcs) = items[2], funcs.count == 1 else {
            XCTFail("supported_functionality should be a 1-element array"); return
        }
        switch funcs[0] {
        case .uint(let n): XCTAssertEqual(n, UInt64(SF_COMPRESSION))
        case .int(let n):  XCTAssertEqual(n, Int64(SF_COMPRESSION))
        default: XCTFail("Expected SF_COMPRESSION value, got \(funcs[0])")
        }
    }

    /// With a display name the first element is UTF-8 bytes of the name.
    func testGetAnnounceAppDataDisplayName() throws {
        let (router, transport) = makeRouter()
        let (_, dest) = try makeIdentityAndRegister(router: router, transport: transport,
                                                    displayName: "Alice")

        guard let appData = router.getAnnounceAppData(destinationHash: dest.hash) else {
            XCTFail("Expected non-nil appData"); return
        }
        guard case .array(let items) = (try? MsgPack.decode(appData)),
              items.count == 3 else {
            XCTFail("Expected 3-element array"); return
        }
        guard case .bytes(let nameBytes) = items[0] else {
            XCTFail("display_name should be bytes, got \(items[0])"); return
        }
        XCTAssertEqual(String(bytes: nameBytes, encoding: .utf8), "Alice")
    }

    /// With a valid stamp cost (1…254) the second element is that integer.
    func testGetAnnounceAppDataStampCost() throws {
        let (router, transport) = makeRouter()
        let (_, dest) = try makeIdentityAndRegister(router: router, transport: transport,
                                                    stampCost: 8)

        guard let appData = router.getAnnounceAppData(destinationHash: dest.hash) else {
            XCTFail("Expected non-nil appData"); return
        }
        guard case .array(let items) = (try? MsgPack.decode(appData)),
              items.count == 3 else {
            XCTFail("Expected 3-element array"); return
        }
        switch items[1] {
        case .int(let n):  XCTAssertEqual(n, 8)
        case .uint(let n): XCTAssertEqual(n, 8)
        default: XCTFail("stamp_cost should be integer, got \(items[1])")
        }
    }

    /// Out-of-range stamp cost (0 or ≥255) is omitted (nil in packed output).
    func testGetAnnounceAppDataInvalidStampCostOmitted() throws {
        let (router, transport) = makeRouter()
        let (_, dest) = try makeIdentityAndRegister(router: router, transport: transport,
                                                    stampCost: 0)

        guard let appData = router.getAnnounceAppData(destinationHash: dest.hash) else {
            XCTFail("Expected non-nil appData"); return
        }
        guard case .array(let items) = (try? MsgPack.decode(appData)),
              items.count == 3 else {
            XCTFail("Expected 3-element array"); return
        }
        XCTAssertEqual(items[1], .nil, "Stamp cost 0 should be omitted (nil)")
    }

    /// The third element is [SF_COMPRESSION] indicating bzip2 support (LXMF 0.9.8+).
    func testGetAnnounceAppDataAdvertisesCompressionSupport() throws {
        let (router, transport) = makeRouter()
        let (_, dest) = try makeIdentityAndRegister(router: router, transport: transport,
                                                    displayName: "Bob")

        guard let appData = router.getAnnounceAppData(destinationHash: dest.hash) else {
            XCTFail("Expected non-nil appData"); return
        }
        // A peer parsing this appData should see compression support
        XCTAssertTrue(compressionSupportFromAppData(appData),
                      "Announced appData should advertise compression support")
    }

    // MARK: - announce

    /// announce for an unknown destination is a no-op (no crash, no throw).
    func testAnnounceUnknownDestinationIsNoop() {
        let (router, _) = makeRouter()
        let unknown = Data(repeating: 0xCD, count: 16)
        XCTAssertNoThrow(try router.announce(destinationHash: unknown),
                         "announce for unknown destination must not throw")
    }

    /// announce for a registered destination doesn't throw (Reticulum.shared may be nil in tests).
    func testAnnounceRegisteredDestinationNoThrow() throws {
        let (router, transport) = makeRouter()
        let (_, dest) = try makeIdentityAndRegister(router: router, transport: transport)
        // Reticulum.shared is nil in unit tests, so Destination.announce returns nil
        // — but the call must not throw.
        XCTAssertNoThrow(try router.announce(destinationHash: dest.hash))
    }

    // MARK: - deliveryLinkAvailable

    /// Returns false when no link has been established.
    func testDeliveryLinkAvailableFalseWhenNoLink() throws {
        let (router, transport) = makeRouter()
        let (_, dest) = try makeIdentityAndRegister(router: router, transport: transport)
        XCTAssertFalse(router.deliveryLinkAvailable(destinationHash: dest.hash),
                       "No link established → should return false")
    }

    /// Returns false for an unregistered destination hash.
    func testDeliveryLinkAvailableFalseForUnknown() {
        let (router, _) = makeRouter()
        let unknown = Data(repeating: 0x11, count: 16)
        XCTAssertFalse(router.deliveryLinkAvailable(destinationHash: unknown))
    }

    // MARK: - getOutboundPropagationCost

    /// Returns nil when no outbound propagation node is configured.
    func testGetOutboundPropagationCostNilWhenNoPNSet() {
        let (router, _) = makeRouter()
        XCTAssertNil(router.getOutboundPropagationCost(),
                     "Should return nil when outbound propagation node is not set")
    }

    /// Returns nil when outbound PN is set but no app data is cached.
    func testGetOutboundPropagationCostNilWhenNoAppData() {
        let (router, _) = makeRouter()
        let fakePN = Data(repeating: 0x42, count: 16)
        router.outboundPropagationNode = fakePN
        XCTAssertNil(router.getOutboundPropagationCost(),
                     "Should return nil when PN app data is not cached")
    }
}
