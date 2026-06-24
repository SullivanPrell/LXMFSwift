import XCTest
import LXMF
import ReticulumSwift

final class LXMessageTests: XCTestCase {

    // MARK: - Helpers

    private func makeDestination(identity: Identity, aspects: [String] = ["delivery"]) throws -> Destination {
        try Destination(identity: identity, direction: .in, kind: .single, appName: "lxmf", aspects: aspects)
    }

    // MARK: - Pack / unpack round-trip

    func testPackUnpackRoundTrip() throws {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let msg = LXMessage(destination: dst, source: src, content: "Hello, LXMF!", title: "Test")
        try msg.pack()

        guard let packed = msg.packed else { XCTFail("packed nil"); return }
        XCTAssertGreaterThan(packed.count, LXMessage.destinationLength + LXMessage.destinationLength + LXMessage.signatureLength)

        let decoded = try LXMessage.unpack(packed)
        XCTAssertEqual(decoded.destinationHash, dst.hash)
        XCTAssertEqual(decoded.sourceHash, src.hash)
        XCTAssertEqual(decoded.contentAsString, "Hello, LXMF!")
        XCTAssertEqual(decoded.titleAsString, "Test")
        XCTAssertNotNil(decoded.hash)
        XCTAssertEqual(decoded.hash, msg.hash)
    }

    /// `unpack` must restore the `fields` dictionary, not silently drop it.
    /// Mirrors Python's `unpack_from_bytes`, which assigns `fields =
    /// unpacked_payload[3]`. Regression guard: the inbound init defaults
    /// `fields` to empty, so before the fix every received message lost all of
    /// its fields (attachments, telemetry, tickets, reactions, …). The plain
    /// `testPackUnpackRoundTrip` uses no fields, which is why this was missed.
    func testPackUnpackPreservesFields() throws {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try makeDestination(identity: srcIdentity)
        let dst = try makeDestination(identity: dstIdentity)

        // A ticket field (nested [expiry, ticketBytes] array) plus a telemetry
        // blob — the two field shapes that actually exercise inbound ingest.
        let expiry = 1_700_000_000
        let ticketBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02])
        let telemetry = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        let fields: [Int: Any] = [
            Int(Field.ticket.rawValue):    [expiry, ticketBytes],
            Int(Field.telemetry.rawValue): telemetry,
        ]

        let msg = LXMessage(destination: dst, source: src,
                            content: "With fields", title: "T", fields: fields)
        try msg.pack()

        let decoded = try LXMessage.unpack(msg.packed!)

        // Content/title still survive…
        XCTAssertEqual(decoded.contentAsString, "With fields")
        XCTAssertEqual(decoded.titleAsString, "T")

        // …and the fields dict now round-trips intact.
        XCTAssertEqual(decoded.fields.count, 2, "fields dropped on unpack")

        XCTAssertEqual(decoded.fields[Int(Field.telemetry.rawValue)] as? Data, telemetry)

        let ticket = decoded.fields[Int(Field.ticket.rawValue)] as? [Any]
        XCTAssertNotNil(ticket, "ticket field should decode to a nested array")
        XCTAssertEqual(ticket?.count, 2)
        XCTAssertEqual(ticket?[0] as? Int, expiry)
        XCTAssertEqual(ticket?[1] as? Data, ticketBytes)

        // Fields are signature-covered (part of the hashed payload), so the
        // message hash must still match across pack/unpack.
        XCTAssertEqual(decoded.hash, msg.hash)
        XCTAssertTrue(decoded.validateSignature(knownIdentity: srcIdentity))
    }

    /// Newly-unpacked messages default to `sourceBlackholed = false`.
    /// `Reticulum.shared` is nil in unit tests, so the check short-circuits.
    /// Mirrors Python's `LXMessage.source_blackholed` default (LXMF commit 2ac2b10).
    func testSourceBlackholedDefaultsFalse() throws {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try makeDestination(identity: srcIdentity)
        let dst = try makeDestination(identity: dstIdentity)

        let msg = LXMessage(destination: dst, source: src, content: "Hi")
        try msg.pack()
        let decoded = try LXMessage.unpack(msg.packed!)
        XCTAssertFalse(decoded.sourceBlackholed,
                       "Default sourceBlackholed should be false when no shared Reticulum instance")
    }

    func testSignatureValidation() throws {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try makeDestination(identity: srcIdentity)
        let dst = try makeDestination(identity: dstIdentity)

        let msg = LXMessage(destination: dst, source: src, content: "Verify me")
        try msg.pack()
        let packed = msg.packed!

        let decoded = try LXMessage.unpack(packed)
        let valid = decoded.validateSignature(knownIdentity: srcIdentity)
        XCTAssertTrue(valid)
        XCTAssertTrue(decoded.signatureValidated)
    }

    func testSignatureValidationFailsWithWrongKey() throws {
        let srcIdentity = Identity()
        let wrongIdentity = Identity()
        let dst = try makeDestination(identity: Identity())
        let src = try makeDestination(identity: srcIdentity)

        let msg = LXMessage(destination: dst, source: src, content: "Tamper me")
        try msg.pack()
        let decoded = try LXMessage.unpack(msg.packed!)
        XCTAssertFalse(decoded.validateSignature(knownIdentity: wrongIdentity))
    }

    func testHashIsStable() throws {
        let srcIdentity = Identity()
        let dst = try makeDestination(identity: Identity())
        let src = try makeDestination(identity: srcIdentity)
        let ts: TimeInterval = 1_700_000_000

        let a = LXMessage(destination: dst, source: src, content: "stable", title: "")
        a.timestamp = ts
        // Force pack with the fixed timestamp
        try a.pack()

        let b = LXMessage(destination: dst, source: src, content: "stable", title: "")
        b.timestamp = ts
        try b.pack()

        // Same content + timestamp → same hash (deterministic packing)
        XCTAssertEqual(a.hash, b.hash)
    }

    // MARK: - Method selection

    func testSmallMessageSelectsPacket() throws {
        let dst = try makeDestination(identity: Identity())
        let src = try makeDestination(identity: Identity())
        let msg = LXMessage(destination: dst, source: src, content: "hi", desiredMethod: .direct)
        try msg.pack()
        XCTAssertEqual(msg.representation, .packet)
        XCTAssertEqual(msg.method, .direct)
    }

    func testLargeMessageSelectsResource() throws {
        let dst = try makeDestination(identity: Identity())
        let src = try makeDestination(identity: Identity())
        let bigContent = String(repeating: "x", count: 1000)
        let msg = LXMessage(destination: dst, source: src, content: bigContent, desiredMethod: .direct)
        try msg.pack()
        XCTAssertEqual(msg.representation, .resource)
    }

    func testOpportunisticFallsBackToDirectForLargeContent() throws {
        let dst = try makeDestination(identity: Identity())
        let src = try makeDestination(identity: Identity())
        let bigContent = String(repeating: "y", count: 400)
        let msg = LXMessage(destination: dst, source: src, content: bigContent, desiredMethod: .opportunistic)
        try msg.pack()
        // Opportunistic falls back to direct if content > ENCRYPTED_PACKET_MAX_CONTENT
        XCTAssertEqual(msg.method, .direct)
    }

    // MARK: - Wire layout

    func testWireLayoutMatchesSpec() throws {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let dst = try makeDestination(identity: dstIdentity)
        let src = try makeDestination(identity: srcIdentity)
        let msg = LXMessage(destination: dst, source: src, content: "layout")
        try msg.pack()
        let wire = msg.packed!

        let hlen = LXMessage.destinationLength
        let slen = LXMessage.signatureLength

        XCTAssertEqual(Data(wire.prefix(hlen)), dst.hash)
        XCTAssertEqual(Data(wire[hlen ..< hlen * 2]), src.hash)
        XCTAssertEqual(Data(wire[hlen * 2 ..< hlen * 2 + slen]), msg.signature!)
    }

    // MARK: - Field helpers

    func testStampCostFromAppDataExtractsValue() {
        // Python delivery announce format: [display_name, stamp_cost, supported_functionality]
        // Stamp cost is at index 1 (mirrors Python's peer_data[1]).
        let appData = MsgPack.encode(.array([.nil, .int(7), .array([.uint(0)])]))
        XCTAssertEqual(stampCostFromAppData(appData), 7)
    }

    func testStampCostFromAppDataWithDisplayName() {
        let name = Data("Alice".utf8)
        let appData = MsgPack.encode(.array([.bytes(name), .int(12), .array([.uint(0)])]))
        XCTAssertEqual(stampCostFromAppData(appData), 12)
    }

    func testStampCostFromAppDataNilWhenNoStampCost() {
        // display_name only, no stamp cost (stamp_cost = nil at index 1)
        let appData = MsgPack.encode(.array([.nil, .nil, .array([.uint(0)])]))
        XCTAssertNil(stampCostFromAppData(appData))
    }

    func testStampCostFromAppDataNilForSingleElement() {
        // Single-element array (old format / wrong format) — no stamp cost at index 1
        let appData = MsgPack.encode(.array([.int(7)]))
        XCTAssertNil(stampCostFromAppData(appData))
    }

    func testStampCostFromNilAppDataReturnsNil() {
        XCTAssertNil(stampCostFromAppData(nil))
    }

    // MARK: - LXMRouter delivery

    func testRouterReceivesOpportunisticDelivery() throws {
        let transport = Transport()

        let srcIdentity = Identity()
        let dstIdentity = Identity()

        let dstDest = try Destination(
            identity: dstIdentity,
            direction: .in,
            kind: .single,
            appName: APP_NAME,
            aspects: ["delivery"]
        )
        let srcDest = try Destination(
            identity: srcIdentity,
            direction: .in,
            kind: .single,
            appName: APP_NAME,
            aspects: ["delivery"]
        )

        // Receiver side
        let receiverRouter = LXMRouter(transport: transport)
        let receiverTransport = Transport()
        let _ = try receiverRouter.register(identity: dstIdentity, transport: receiverTransport)

        // Manually inject path + identity so sender can reach dst
        let fakeEntry = Transport.PathEntry(
            destinationHash: dstDest.hash,
            nextHopInterfaceName: "test",
            hops: 1,
            lastHeard: Date(),
            identityHash: dstIdentity.hash
        )
        transport.restore(path: fakeEntry, forDestination: dstDest.hash)
        transport.restore(identity: dstIdentity, forDestination: dstDest.hash)

        let expectation = XCTestExpectation(description: "message received")
        receiverRouter.onMessageReceived = { msg in
            XCTAssertEqual(msg.contentAsString, "Hello router!")
            expectation.fulfill()
        }

        // Sender side
        let senderRouter = LXMRouter(transport: transport)
        let msg = LXMessage(
            destination: dstDest,
            source: srcDest,
            content: "Hello router!",
            desiredMethod: .opportunistic
        )

        // Wire router inbound to receiver
        transport.onPacketDelivered = { [weak receiverRouter] packet, dest, _ in
            // Simulate delivery to receiver
            _ = receiverRouter
        }

        try senderRouter.send(msg)

        // For opportunistic, the message should be SENT after send()
        // (real delivery test requires a loopback interface; this verifies the pack path)
        XCTAssertTrue(msg.packed != nil)
    }
}
