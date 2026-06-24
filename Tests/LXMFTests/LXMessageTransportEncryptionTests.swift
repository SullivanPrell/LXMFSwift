import XCTest
import Foundation
import LXMF
import ReticulumSwift

/// Tests for LXMessage.determineTransportEncryption() and getPropagationStamp(targetCost:).
final class LXMessageTransportEncryptionTests: XCTestCase {

    // MARK: - Helpers

    private func makeMessage(desiredMethod: LXMessage.Method = .direct) throws -> LXMessage {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let msg = LXMessage(destination: dst, source: src, content: "Test",
                            desiredMethod: desiredMethod)
        try msg.pack()
        msg.method = desiredMethod  // set method as pack() would
        return msg
    }

    // MARK: - determineTransportEncryption tests

    /// Test 1: DIRECT method to SINGLE destination → Curve25519 encrypted.
    func testDirectSingleIsEC() throws {
        let msg = try makeMessage(desiredMethod: .direct)
        msg.method = .direct
        msg.determineTransportEncryption()
        XCTAssertTrue(msg.transportEncrypted)
        XCTAssertEqual(msg.transportEncryptionDescription, LXMessage.encryptionDescriptionEC)
    }

    /// Test 2: OPPORTUNISTIC to SINGLE destination → Curve25519.
    func testOpportunisticSingleIsEC() throws {
        let msg = try makeMessage(desiredMethod: .opportunistic)
        msg.method = .opportunistic
        msg.determineTransportEncryption()
        XCTAssertTrue(msg.transportEncrypted)
        XCTAssertEqual(msg.transportEncryptionDescription, LXMessage.encryptionDescriptionEC)
    }

    /// Test 3: PROPAGATED to SINGLE destination → Curve25519.
    func testPropagatedSingleIsEC() throws {
        let msg = try makeMessage(desiredMethod: .propagated)
        msg.method = .propagated
        msg.determineTransportEncryption()
        XCTAssertTrue(msg.transportEncrypted)
        XCTAssertEqual(msg.transportEncryptionDescription, LXMessage.encryptionDescriptionEC)
    }

    /// Test 4: Unknown method → Unencrypted.
    func testUnknownMethodIsUnencrypted() throws {
        let msg = try makeMessage()
        msg.method = .unknown
        msg.determineTransportEncryption()
        XCTAssertFalse(msg.transportEncrypted)
        XCTAssertEqual(msg.transportEncryptionDescription, LXMessage.encryptionDescriptionUnencrypted)
    }

    /// Test 5: Calling determineTransportEncryption twice is idempotent.
    func testIdempotent() throws {
        let msg = try makeMessage(desiredMethod: .direct)
        msg.method = .direct
        msg.determineTransportEncryption()
        let enc1 = msg.transportEncryptionDescription
        msg.determineTransportEncryption()
        XCTAssertEqual(msg.transportEncryptionDescription, enc1)
    }

    // MARK: - getPropagationStamp tests

    /// Test 6: getPropagationStamp returns non-nil for a packed message with targetCost=1.
    func testGetPropagationStampReturnsStamp() throws {
        let msg = try makeMessage()
        let stamp = msg.getPropagationStamp(targetCost: 1)
        XCTAssertNotNil(stamp, "getPropagationStamp must return a stamp for packed message with cost=1")
    }

    /// Test 7: Stamp is 32 bytes.
    func testGetPropagationStampIs32Bytes() throws {
        let msg = try makeMessage()
        let stamp = msg.getPropagationStamp(targetCost: 1)
        XCTAssertEqual(stamp?.count, LXStamper.stampSize)
    }

    /// Test 8: getPropagationStamp returns nil for an unpacked message (no transient ID).
    func testGetPropagationStampNilForUnpacked() throws {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let msg = LXMessage(destination: dst, source: src, content: "Unpacked")
        // Do NOT call pack()
        let stamp = msg.getPropagationStamp(targetCost: 1)
        XCTAssertNil(stamp, "getPropagationStamp must return nil when message is not packed")
    }

    /// Test 9: Stamp is valid against the propagation workblock.
    func testGetPropagationStampIsValid() throws {
        let msg = try makeMessage()
        guard let messageID = msg.messageID else {
            XCTFail("messageID must be set after pack()"); return
        }
        let targetCost = 1
        let stamp = msg.getPropagationStamp(targetCost: targetCost)
        guard let stamp else {
            XCTFail("getPropagationStamp returned nil"); return
        }
        let workblock = LXStamper.stampWorkblock(material: messageID, expandRounds: LXStamper.pnExpandRounds)
        XCTAssertTrue(LXStamper.stampValid(stamp: stamp, targetCost: targetCost, workblock: workblock),
                      "Propagation stamp must be valid against PN workblock")
    }

    /// Test 10: Calling getPropagationStamp twice returns the same (cached) stamp.
    func testGetPropagationStampCached() throws {
        let msg = try makeMessage()
        let stamp1 = msg.getPropagationStamp(targetCost: 1)
        let stamp2 = msg.getPropagationStamp(targetCost: 1)
        XCTAssertEqual(stamp1, stamp2, "getPropagationStamp must return cached stamp on second call")
    }
}
