import XCTest
import Foundation
import LXMF
import ReticulumSwift

/// Tests for the LXMF ticket system parity with Python LXMF 0.9.9:
///   - LXMessage ticket constants (TICKET_LENGTH, TICKET_EXPIRY, etc.)
///   - LXMessage.outboundTicket integration in pack() → ticket-based stamp
///   - LXMRouter ticket API: generateTicket, rememberTicket, getOutboundTicket,
///     getOutboundTicketExpiry, getInboundTickets, cleanAvailableTickets
final class LXMTicketSystemTests: XCTestCase {

    // MARK: - Helpers

    private func makePacked() throws -> LXMessage {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let msg = LXMessage(destination: dst, source: src, content: "Hello")
        try msg.pack()
        return msg
    }

    private func makeRouter() -> (LXMRouter, Transport) {
        let t = Transport()
        return (LXMRouter(transport: t), t)
    }

    private func makeDestHash() -> Data { Data(repeating: 0xAA, count: 16) }

    // MARK: - LXMessage ticket constants

    func testTicketLength() {
        XCTAssertEqual(LXMessage.ticketLength, 16,
                       "TICKET_LENGTH = TRUNCATED_HASHLENGTH/8 = 128/8 = 16")
    }

    func testTicketExpiry() {
        XCTAssertEqual(LXMessage.ticketExpiry, 21 * 24 * 60 * 60,
                       "TICKET_EXPIRY = 21 days in seconds")
    }

    func testTicketGrace() {
        XCTAssertEqual(LXMessage.ticketGrace, 5 * 24 * 60 * 60,
                       "TICKET_GRACE = 5 days in seconds")
    }

    func testTicketRenew() {
        XCTAssertEqual(LXMessage.ticketRenew, 14 * 24 * 60 * 60,
                       "TICKET_RENEW = 14 days in seconds")
    }

    func testTicketInterval() {
        XCTAssertEqual(LXMessage.ticketInterval, 1 * 24 * 60 * 60,
                       "TICKET_INTERVAL = 1 day in seconds")
    }

    func testCostTicket() {
        XCTAssertEqual(LXMessage.costTicket, 0x100,
                       "COST_TICKET = 256 (0x100)")
    }

    // MARK: - LXMessage.outboundTicket in pack()

    /// When outboundTicket is set, pack() produces a 16-byte truncated-hash stamp.
    func testPackWithTicketProduces16ByteStamp() throws {
        let msg = try makePacked()
        // Re-create unpacked to test with ticket (pack() is idempotent-blocked otherwise)
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let msg2 = LXMessage(destination: dst, source: src, content: "Ticket test")
        msg2.outboundTicket = Data(repeating: 0x77, count: LXMessage.ticketLength)
        try msg2.pack()
        guard let stamp = msg2.stamp else {
            XCTFail("stamp must be set when outboundTicket is present"); return
        }
        XCTAssertEqual(stamp.count, 16,
                       "Ticket stamp must be 16 bytes (truncated hash)")
        _ = msg  // silence unused warning
    }

    /// Ticket stamp equals truncatedHash(ticket + messageID).
    func testPackWithTicketStampIsCorrectHash() throws {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let ticket = Data(repeating: 0x55, count: LXMessage.ticketLength)
        let msg = LXMessage(destination: dst, source: src, content: "Ticket hash")
        msg.outboundTicket = ticket
        try msg.pack()

        guard let stamp = msg.stamp, let messageID = msg.messageID else {
            XCTFail("stamp and messageID must be set"); return
        }
        let expected = Hashes.truncatedHash(ticket + messageID)
        XCTAssertEqual(stamp, expected,
                       "Ticket stamp must equal truncatedHash(ticket + messageID)")
    }

    /// stampValue is set to costTicket (0x100) when a ticket is used.
    func testPackWithTicketSetsCostTicketStampValue() throws {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let msg = LXMessage(destination: dst, source: src, content: "Stamp value")
        msg.outboundTicket = Data(repeating: 0xAB, count: LXMessage.ticketLength)
        try msg.pack()
        XCTAssertEqual(msg.stampValue, LXMessage.costTicket,
                       "stampValue must be costTicket (0x100) when outboundTicket is used")
    }

    /// Wrong-length ticket is ignored; pack() falls through to normal stamp logic.
    func testPackIgnoresWrongLengthTicket() throws {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let msg = LXMessage(destination: dst, source: src, content: "Wrong ticket")
        msg.outboundTicket = Data(repeating: 0x01, count: 8)  // Wrong: 8 bytes, not 16
        // No stampCost set → no stamp expected
        try msg.pack()
        XCTAssertNil(msg.stamp, "Wrong-length ticket must be ignored, no stamp without cost")
    }

    // MARK: - LXMRouter ticket API

    /// rememberTicket then getOutboundTicket returns the stored ticket.
    func testRememberAndGetOutboundTicket() {
        let (router, _) = makeRouter()
        let dest = makeDestHash()
        let ticket = Data(count: LXMessage.ticketLength)
        let expiry = Date().timeIntervalSince1970 + LXMessage.ticketExpiry
        router.rememberTicket(destinationHash: dest, expiry: expiry, ticket: ticket)
        XCTAssertEqual(router.getOutboundTicket(destinationHash: dest), ticket,
                       "getOutboundTicket must return the stored ticket while valid")
    }

    /// getOutboundTicket returns nil for expired ticket.
    func testGetOutboundTicketNilWhenExpired() {
        let (router, _) = makeRouter()
        let dest = makeDestHash()
        let ticket = Data(count: LXMessage.ticketLength)
        let expiry = Date().timeIntervalSince1970 - 1  // already expired
        router.rememberTicket(destinationHash: dest, expiry: expiry, ticket: ticket)
        XCTAssertNil(router.getOutboundTicket(destinationHash: dest),
                     "Expired ticket must return nil")
    }

    /// getOutboundTicket returns nil for unknown destination.
    func testGetOutboundTicketNilForUnknown() {
        let (router, _) = makeRouter()
        XCTAssertNil(router.getOutboundTicket(destinationHash: makeDestHash()))
    }

    /// getOutboundTicketExpiry returns expiry for a valid ticket.
    func testGetOutboundTicketExpiry() {
        let (router, _) = makeRouter()
        let dest = makeDestHash()
        let ticket = Data(count: LXMessage.ticketLength)
        let expiry = Date().timeIntervalSince1970 + LXMessage.ticketExpiry
        router.rememberTicket(destinationHash: dest, expiry: expiry, ticket: ticket)
        XCTAssertEqual(router.getOutboundTicketExpiry(destinationHash: dest), expiry,
                       "getOutboundTicketExpiry must return stored expiry")
    }

    /// getOutboundTicketExpiry returns nil for expired ticket.
    func testGetOutboundTicketExpiryNilWhenExpired() {
        let (router, _) = makeRouter()
        let dest = makeDestHash()
        let ticket = Data(count: LXMessage.ticketLength)
        let expiry = Date().timeIntervalSince1970 - 1
        router.rememberTicket(destinationHash: dest, expiry: expiry, ticket: ticket)
        XCTAssertNil(router.getOutboundTicketExpiry(destinationHash: dest))
    }

    /// generateTicket returns a non-nil [expiry, ticket] entry.
    func testGenerateTicketReturnsEntry() {
        let (router, _) = makeRouter()
        let dest = makeDestHash()
        let entry = router.generateTicket(destinationHash: dest)
        XCTAssertNotNil(entry, "generateTicket must return a non-nil entry")
        XCTAssertEqual(entry?.ticket.count, LXMessage.ticketLength,
                       "generated ticket must be TICKET_LENGTH bytes")
    }

    /// generateTicket reuses an unexpired ticket with enough validity remaining.
    func testGenerateTicketReusesExistingWithEnoughValidity() {
        let (router, _) = makeRouter()
        let dest = makeDestHash()
        guard let first = router.generateTicket(destinationHash: dest) else {
            XCTFail("First generateTicket must succeed"); return
        }
        guard let second = router.generateTicket(destinationHash: dest) else {
            XCTFail("Second generateTicket must succeed"); return
        }
        XCTAssertEqual(first.ticket, second.ticket,
                       "generateTicket must reuse the same ticket when enough validity remains")
    }

    /// getInboundTickets returns non-nil list containing the generated ticket.
    func testGetInboundTicketsReturnsGeneratedTicket() {
        let (router, _) = makeRouter()
        let dest = makeDestHash()
        guard let entry = router.generateTicket(destinationHash: dest) else {
            XCTFail("generateTicket must succeed"); return
        }
        guard let tickets = router.getInboundTickets(destinationHash: dest) else {
            XCTFail("getInboundTickets must return non-nil after generateTicket"); return
        }
        XCTAssertTrue(tickets.contains(entry.ticket),
                      "getInboundTickets must include the generated ticket")
    }

    /// getInboundTickets returns nil when no tickets have been generated.
    func testGetInboundTicketsNilForUnknown() {
        let (router, _) = makeRouter()
        XCTAssertNil(router.getInboundTickets(destinationHash: makeDestHash()),
                     "getInboundTickets must return nil when no tickets exist")
    }

    /// cleanAvailableTickets removes an expired outbound ticket.
    func testCleanAvailableTicketsSweepsExpiredOutbound() {
        let (router, _) = makeRouter()
        let dest = makeDestHash()
        let ticket = Data(count: LXMessage.ticketLength)
        let expiry = Date().timeIntervalSince1970 - 1  // already expired
        router.rememberTicket(destinationHash: dest, expiry: expiry, ticket: ticket)
        router.cleanAvailableTickets()
        XCTAssertNil(router.getOutboundTicket(destinationHash: dest),
                     "cleanAvailableTickets must remove expired outbound tickets")
    }
}
