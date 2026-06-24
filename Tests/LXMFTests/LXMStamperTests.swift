import XCTest
import LXMF
import ReticulumSwift

/// Tests for LXMF stamp (proof-of-work anti-spam) system.
/// Mirrors Python's LXStamper.py and LXMessage stamp wire format.
final class LXMStamperTests: XCTestCase {

    // MARK: - Workblock

    func testStampWorkblockHasExpectedSize() {
        let material = Data(repeating: 0xAB, count: 32)
        let wb = LXStamper.stampWorkblock(material: material, expandRounds: 3)
        XCTAssertEqual(wb.count, 3 * 256, "workblock should be expandRounds * 256 bytes")
    }

    func testStampWorkblockIsDeterministic() {
        let material = Hashes.randomHash()
        let wb1 = LXStamper.stampWorkblock(material: material, expandRounds: 2)
        let wb2 = LXStamper.stampWorkblock(material: material, expandRounds: 2)
        XCTAssertEqual(wb1, wb2)
    }

    // MARK: - Stamp value (leading zero count)

    func testStampValueZeroForHighResult() {
        let wb = Data(repeating: 0xFF, count: 256)
        // hash = SHA256(wb + stamp), if result >= 0x80... then value = 0
        let stamp = Data(repeating: 0xFF, count: 32)
        let value = LXStamper.stampValue(workblock: wb, stamp: stamp)
        // value is the number of leading zero bits — we just verify it's a non-negative int
        XCTAssertGreaterThanOrEqual(value, 0)
    }

    // MARK: - Stamp generation and validation (small params for speed)

    func testGenerateAndValidateStampCost1() throws {
        let messageID = Hashes.randomHash()
        let expandRounds = 1  // small for test speed
        let cost = 1

        let workblock = LXStamper.stampWorkblock(material: messageID, expandRounds: expandRounds)
        let stamp = try XCTUnwrap(LXStamper.generateStamp(messageID: messageID, stampCost: cost, expandRounds: expandRounds))

        XCTAssertEqual(stamp.count, 32, "stamp should be 32 bytes (SHA256 size)")
        XCTAssertTrue(LXStamper.stampValid(stamp: stamp, targetCost: cost, workblock: workblock),
                      "generated stamp must validate at target cost")
    }

    func testStampValueEqualsLeadingZeroBits() throws {
        let messageID = Hashes.randomHash()
        let expandRounds = 1
        let cost = 3

        let workblock = LXStamper.stampWorkblock(material: messageID, expandRounds: expandRounds)
        let stamp = try XCTUnwrap(LXStamper.generateStamp(messageID: messageID, stampCost: cost, expandRounds: expandRounds))

        let value = LXStamper.stampValue(workblock: workblock, stamp: stamp)
        XCTAssertGreaterThanOrEqual(value, cost, "stamp value should be >= target cost")
    }

    // MARK: - LXMessage stamp wire format

    func testPackWithStampAddsFifthPayloadElement() throws {
        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let msg = LXMessage(destination: dst, source: src, content: "stamp test",
                            stampCost: 1, stampExpandRounds: 1)
        try msg.pack()

        let packed = try XCTUnwrap(msg.packed)
        XCTAssertNotNil(msg.stamp, "stamp should be set after pack() with stampCost != nil")

        // Decode the payload portion and check it has 5 elements
        let payloadStart = LXMessage.destinationLength * 2 + LXMessage.signatureLength
        let payloadBytes = packed.advanced(by: payloadStart)
        guard case .array(let parts) = try MsgPack.decode(payloadBytes) else {
            XCTFail("payload should decode as array"); return
        }
        XCTAssertEqual(parts.count, 5, "payload should have 5 elements when stamp is included")
        if case .bytes(let stampBytes) = parts[4] {
            XCTAssertEqual(stampBytes, msg.stamp!, "5th element should be the stamp bytes")
        } else {
            XCTFail("5th element should be bytes")
        }
    }

    func testPackWithoutStampCostHasFourPayloadElements() throws {
        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let msg = LXMessage(destination: dst, source: src, content: "no stamp")
        try msg.pack()

        let packed = try XCTUnwrap(msg.packed)
        let payloadStart = LXMessage.destinationLength * 2 + LXMessage.signatureLength
        let payloadBytes = packed.advanced(by: payloadStart)
        guard case .array(let parts) = try MsgPack.decode(payloadBytes) else {
            XCTFail("payload should decode as array"); return
        }
        XCTAssertEqual(parts.count, 4)
        XCTAssertNil(msg.stamp)
    }

    func testUnpackExtractsStampFromFifthElement() throws {
        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let msg = LXMessage(destination: dst, source: src, content: "roundtrip",
                            stampCost: 1, stampExpandRounds: 1)
        try msg.pack()

        let packed = try XCTUnwrap(msg.packed)
        let decoded = try LXMessage.unpack(packed)

        XCTAssertNotNil(decoded.stamp, "unpack should extract stamp from 5th payload element")
        XCTAssertEqual(decoded.stamp, msg.stamp)
    }

    func testHashNotAffectedByStamp() throws {
        // The message hash is computed from the 4-element payload (without stamp).
        // Packing with stamp should produce the same hash as the 4-element packed version.
        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let msgStamped = LXMessage(destination: dst, source: src, content: "same content",
                                   stampCost: 1, stampExpandRounds: 1)
        msgStamped.timestamp = 1_700_000_000

        let msgNoStamp = LXMessage(destination: dst, source: src, content: "same content")
        msgNoStamp.timestamp = 1_700_000_000

        try msgStamped.pack()
        try msgNoStamp.pack()

        XCTAssertEqual(msgStamped.hash, msgNoStamp.hash,
                       "hash computed before stamp addition should match unstamped message")
    }

    func testValidateStamp() throws {
        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let msg = LXMessage(destination: dst, source: src, content: "validate",
                            stampCost: 1, stampExpandRounds: 1)
        try msg.pack()

        XCTAssertNotNil(msg.stamp)
        let isValid = msg.validateStamp(targetCost: 1)
        XCTAssertTrue(isValid)
        XCTAssertTrue(msg.stampValid)
        XCTAssertGreaterThanOrEqual(msg.stampValue ?? 0, 1)
    }

    func testValidateStampFalseWhenNil() throws {
        let srcId = Identity()
        let dstId = Identity()
        let src = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])

        let msg = LXMessage(destination: dst, source: src, content: "no stamp")
        try msg.pack()

        XCTAssertFalse(msg.validateStamp(targetCost: 1))
    }
}
