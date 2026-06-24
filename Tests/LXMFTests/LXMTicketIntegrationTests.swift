import XCTest
import Foundation
import LXMF
import ReticulumSwift

/// Tests for the ticket integration gaps:
///   - LXMessage.validateStamp(targetCost:tickets:) ticket-based stamp validation
///   - LXMessage.includeTicket flag
///   - LXMRouter.send() wires outboundTicket from stored tickets before packing
final class LXMTicketIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makeUnpacked(stampCost: Int? = nil) throws -> LXMessage {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let msg = LXMessage(destination: dst, source: src, content: "Ticket integration")
        if let cost = stampCost { msg.stampCost = cost }
        return msg
    }

    private func makeRouter() -> (LXMRouter, Transport) {
        let t = Transport()
        return (LXMRouter(transport: t), t)
    }

    // MARK: - validateStamp(targetCost:tickets:)

    /// Ticket-validated stamp: validateStamp returns true when stamp matches a known ticket.
    func testValidateStampWithMatchingTicket() throws {
        let msg = try makeUnpacked()
        let ticket = Data(repeating: 0x44, count: LXMessage.ticketLength)
        msg.outboundTicket = ticket
        try msg.pack()

        guard let messageID = msg.messageID else { XCTFail("messageID must be set"); return }
        // stamp = truncatedHash(ticket + messageID)
        let expectedStamp = Hashes.truncatedHash(ticket + messageID)
        XCTAssertEqual(msg.stamp, expectedStamp, "Ticket stamp should match expected hash")

        // Validate using the ticket list
        let isValid = msg.validateStamp(targetCost: 1, tickets: [ticket])
        XCTAssertTrue(isValid, "validateStamp must return true when stamp matches an inbound ticket")
    }

    /// stampValue is set to costTicket after ticket-based validation.
    func testValidateStampSetsStampValueToCostTicket() throws {
        let msg = try makeUnpacked()
        let ticket = Data(repeating: 0x33, count: LXMessage.ticketLength)
        msg.outboundTicket = ticket
        try msg.pack()

        _ = msg.validateStamp(targetCost: 1, tickets: [ticket])
        XCTAssertEqual(msg.stampValue, LXMessage.costTicket,
                       "stampValue must be costTicket after ticket validation")
    }

    /// Non-matching ticket list falls through to PoW validation (returns false for no-stamp msg).
    func testValidateStampFallsThroughToPoWWhenNoTicketMatch() throws {
        let msg = try makeUnpacked(stampCost: nil)  // no stamp, no ticket
        try msg.pack()
        // No stamp, no ticket → PoW validation should fail (stamp is nil)
        let isValid = msg.validateStamp(targetCost: 1, tickets: [Data(repeating: 0xFF, count: 16)])
        XCTAssertFalse(isValid, "Should return false: no stamp, ticket doesn't match anything")
    }

    /// Without a tickets list, existing PoW validation still works normally.
    func testValidateStampWithoutTicketsListWorksNormally() throws {
        let msg = try makeUnpacked(stampCost: 1)
        try msg.pack()
        guard msg.stamp != nil else { XCTFail("stamp must be generated"); return }
        let isValid = msg.validateStamp(targetCost: 1)
        XCTAssertTrue(isValid, "Normal PoW stamp validation must still work without tickets param")
    }

    // MARK: - LXMessage.includeTicket

    /// Default value is false.
    func testIncludeTicketDefaultIsFalse() throws {
        let msg = try makeUnpacked()
        XCTAssertFalse(msg.includeTicket, "includeTicket must default to false")
    }

    /// Can be set to true.
    func testIncludeTicketCanBeSetTrue() throws {
        let msg = try makeUnpacked()
        msg.includeTicket = true
        XCTAssertTrue(msg.includeTicket)
    }

    // MARK: - LXMRouter.send() ticket wiring

    /// send() sets outboundTicket on the message from the router's stored tickets before packing.
    func testSendAppliesOutboundTicketBeforePacking() throws {
        let (router, transport) = makeRouter()
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])

        // Store a ticket for the destination
        let ticket = Data(repeating: 0x99, count: LXMessage.ticketLength)
        let expiry = Date().timeIntervalSince1970 + LXMessage.ticketExpiry
        router.rememberTicket(destinationHash: dst.hash, expiry: expiry, ticket: ticket)

        let msg = LXMessage(destination: dst, source: src, content: "With ticket")
        // Don't set outboundTicket manually — router.send() should do it
        XCTAssertNil(msg.outboundTicket, "outboundTicket must be nil before send()")

        // Register source so the destination lookup works
        try router.register(identity: srcIdentity, transport: transport)

        // send() should find the stored ticket, set msg.outboundTicket, then pack
        do {
            try router.send(msg)
        } catch {
            // send() may fail (e.g. no transport path) — that's fine for this test
            // We only care that outboundTicket was set before pack() was called
        }

        XCTAssertEqual(msg.outboundTicket, ticket,
                       "send() must set outboundTicket from stored router tickets before packing")
    }

    /// send() with includeTicket=true adds a ticket entry to message fields.
    func testSendWithIncludeTicketAddsTicketToFields() throws {
        let (router, transport) = makeRouter()
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])

        try router.register(identity: srcIdentity, transport: transport)

        let msg = LXMessage(destination: dst, source: src, content: "Include ticket")
        msg.includeTicket = true

        do {
            try router.send(msg)
        } catch {
            // Delivery failure OK — we're just checking that the field was added
        }

        let ticketFieldKey = Int(Field.ticket.rawValue)
        XCTAssertNotNil(msg.fields[ticketFieldKey],
                        "send() with includeTicket=true must add FIELD_TICKET to message fields")
    }
}
