import XCTest
@testable import LXMF
import ReticulumSwift

/// Tests for the central inbound-delivery gate (`finalizeInboundDelivery`),
/// which mirrors Python `LXMRouter.lxmf_delivery`: ticket ingest, stamp
/// validation/enforcement, ignore-list filtering, and duplicate suppression.
final class LXMFInboundEnforcementTests: XCTestCase {

    private func makePair() throws -> (router: LXMRouter, src: Destination, dst: Destination,
                                       srcId: Identity, dstId: Identity) {
        let transport = Transport()
        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let router = LXMRouter(transport: transport)
        try router.register(identity: dstId, transport: transport)
        return (router, src, dst, srcId, dstId)
    }

    private func makeInbound(src: Destination, dst: Destination, content: String) throws -> LXMessage {
        let msg = LXMessage(destination: dst, source: src, content: content)
        try msg.pack()           // populates hash / messageID
        return msg
    }

    // MARK: - Duplicate suppression

    func testDuplicateMessageDeliveredOnce() throws {
        let (router, src, dst, _, _) = try makePair()
        let msg = try makeInbound(src: src, dst: dst, content: "dup test")

        var count = 0
        router.onMessageReceived = { _ in count += 1 }

        XCTAssertTrue(router.finalizeInboundDelivery(msg))
        XCTAssertFalse(router.finalizeInboundDelivery(msg), "second delivery of same hash must be suppressed")
        XCTAssertEqual(count, 1)
    }

    // MARK: - Ignore list

    func testIgnoredSourceIsDropped() throws {
        let (router, src, dst, _, _) = try makePair()
        let msg = try makeInbound(src: src, dst: dst, content: "from ignored")

        router.ignoreDestination(destinationHash: src.hash)
        var delivered = false
        router.onMessageReceived = { _ in delivered = true }

        XCTAssertFalse(router.finalizeInboundDelivery(msg))
        XCTAssertFalse(delivered)
    }

    // MARK: - Ticket ingest

    func testTicketIngestRemembersOutboundTicket() throws {
        let (router, src, dst, _, _) = try makePair()
        let msg = try makeInbound(src: src, dst: dst, content: "carries a ticket")

        // Simulate a signature-validated message carrying a FIELD_TICKET.
        msg.signatureValidated = true
        var ticket = Data(count: LXMessage.ticketLength)
        ticket.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, LXMessage.ticketLength, $0.baseAddress!) }
        let expiry = Date().timeIntervalSince1970 + 1_000_000
        msg.fields[Int(Field.ticket.rawValue)] = [expiry, ticket] as [Any]

        XCTAssertNil(router.getOutboundTicket(destinationHash: src.hash))
        XCTAssertTrue(router.finalizeInboundDelivery(msg))
        XCTAssertEqual(router.getOutboundTicket(destinationHash: src.hash), ticket,
                       "an inbound FIELD_TICKET must be remembered for future outbound messages")
    }

    func testUnsignedTicketIsNotIngested() throws {
        let (router, src, dst, _, _) = try makePair()
        let msg = try makeInbound(src: src, dst: dst, content: "spoofed ticket")
        msg.signatureValidated = false   // not validated → ticket must be ignored
        var ticket = Data(count: LXMessage.ticketLength)
        ticket.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, LXMessage.ticketLength, $0.baseAddress!) }
        msg.fields[Int(Field.ticket.rawValue)] = [Date().timeIntervalSince1970 + 1_000_000, ticket] as [Any]

        XCTAssertTrue(router.finalizeInboundDelivery(msg))
        XCTAssertNil(router.getOutboundTicket(destinationHash: src.hash),
                     "tickets on unsigned messages must not be trusted")
    }

    // MARK: - Stamp enforcement

    func testInvalidStampDroppedWhenEnforced() throws {
        let (router, src, dst, _, _) = try makePair()
        let msg = try makeInbound(src: src, dst: dst, content: "no stamp")  // stamp == nil → invalid

        _ = router.setInboundStampCost(destinationHash: dst.hash, stampCost: 8)
        router.enforceStamps()

        var delivered = false
        router.onMessageReceived = { _ in delivered = true }
        XCTAssertFalse(router.finalizeInboundDelivery(msg), "invalid stamp under enforcement must be dropped")
        XCTAssertFalse(delivered)
    }

    func testInvalidStampAllowedWhenNotEnforced() throws {
        let (router, src, dst, _, _) = try makePair()
        let msg = try makeInbound(src: src, dst: dst, content: "no stamp, lenient")

        _ = router.setInboundStampCost(destinationHash: dst.hash, stampCost: 8)
        router.ignoreStamps()   // enforcement disabled (default, set explicitly)

        var delivered = false
        router.onMessageReceived = { _ in delivered = true }
        XCTAssertTrue(router.finalizeInboundDelivery(msg), "invalid stamp must pass when enforcement is off")
        XCTAssertTrue(delivered)
    }
}
