import XCTest
import CryptoKit
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/054`, step 1 — the peering proof-of-work, checked against Python.
///
/// A peering key is a stamp over `receiverIdentityHash ‖ senderIdentityHash` with 25 expand
/// rounds. The sender generates it; the receiver validates it with its own workblock. Both halves
/// live in this package, so a divergence from the reference is invisible to every Swift-only
/// test — it surfaces only as `ERROR_INVALID_KEY` from a Python peer, which the sender cannot
/// distinguish from a genuinely wrong key.
final class PeeringKeyGenerationTests: XCTestCase {

    // MARK: - Against the reference

    func testTheWorkblockMatchesPythonByteForByte() {
        let wb = LXStamper.stampWorkblock(material: PythonPeeringVectors.peeringID,
                                          expandRounds: LXStamper.peeringExpandRounds)

        XCTAssertEqual(wb.count, PythonPeeringVectors.workblockLength,
                       "25 rounds × 256 bytes (LXStamper.py:14)")
        XCTAssertEqual(Data(SHA256.hash(data: wb)), PythonPeeringVectors.workblockDigest,
                       """
                       the peering workblock diverges from the reference. Both the generator and \
                       the validator in this package build it the same way, so every Swift-only \
                       assertion still passes; on the wire a Python peer answers ERROR_INVALID_KEY \
                       and the sender has nothing to log. Check expand rounds, the HKDF \
                       parameters, and the msgpack encoding of the per-round salt index.
                       """)
    }

    func testAPythonGeneratedPeeringKeyValidatesHere() {
        XCTAssertTrue(
            LXStamper.validatePeeringKey(peeringID: PythonPeeringVectors.peeringID,
                                         peeringKey: PythonPeeringVectors.key,
                                         targetCost: PythonPeeringVectors.cost),
            "a key Python generated and accepts must be accepted here")
    }

    func testTheValueOfAPythonKeyIsTheValuePythonReported() {
        let wb = LXStamper.stampWorkblock(material: PythonPeeringVectors.peeringID,
                                          expandRounds: LXStamper.peeringExpandRounds)

        XCTAssertEqual(LXStamper.stampValue(workblock: wb, stamp: PythonPeeringVectors.key),
                       PythonPeeringVectors.value)
    }

    // MARK: - The peering ID

    func testPeeringIDIsReceiverThenSenderAndIs32Bytes() {
        let receiver = Data(repeating: 0x11, count: 16)
        let sender   = Data(repeating: 0x22, count: 16)

        let id = LXStamper.peeringID(receiverIdentityHash: receiver, senderIdentityHash: sender)

        XCTAssertEqual(id.count, 32,
                       """
                       Identity.hash is a *truncated* hash — 16 bytes (RNS/Identity.py:784), not \
                       32. A 64-byte peering ID means the material was built from full hashes or \
                       from destination hashes, and no Python peer will ever validate it.
                       """)
        XCTAssertEqual(id, receiver + sender,
                       """
                       receiver ‖ sender. The generator uses `self.identity.hash + \
                       self.router.identity.hash` (LXMPeer.py:258) — the remote peer first — and \
                       the validator uses `self.identity.hash + remote_identity.hash` \
                       (LXMRouter.py:2300) — itself first. Both are receiver-then-sender; swap \
                       them and every peering attempt is refused with ERROR_INVALID_KEY.
                       """)
    }

    func testARealIdentityHashIs16Bytes() {
        // Pins the premise of the assertion above rather than assuming it.
        XCTAssertEqual(Identity().hash.count, 16)
    }

    // MARK: - Generation returns the value, not just the stamp

    func testGenerateStampReturnsAStampAndItsValue() throws {
        let material = Data(repeating: 0x5A, count: 32)

        let result = try XCTUnwrap(
            LXStamper.generateStamp(material: material, targetCost: 4,
                                    expandRounds: LXStamper.peeringExpandRounds))

        XCTAssertEqual(result.stamp.count, 32)
        XCTAssertGreaterThanOrEqual(result.value, 4,
                                    """
                                    the returned value must be the generated stamp's real value. \
                                    Python returns `(stamp, value)` from one workblock \
                                    (LXStamper.py:123-144) and the peer stores both; a value that \
                                    is merely `>= cost` by construction, or recomputed against a \
                                    different workblock, silently desynchronises \
                                    `peering_key_ready`.
                                    """)

        let wb = LXStamper.stampWorkblock(material: material,
                                          expandRounds: LXStamper.peeringExpandRounds)
        XCTAssertEqual(LXStamper.stampValue(workblock: wb, stamp: result.stamp), result.value,
                       "the reported value must be the value of *that* stamp over *that* material")
    }

    func testTheExistingMessageStampAPIStillWorks() throws {
        // The three existing callers must not change behaviour.
        let id = Data(repeating: 0x7C, count: 32)
        let stamp = try XCTUnwrap(LXStamper.generateStamp(messageID: id, stampCost: 4,
                                                          expandRounds: LXStamper.peeringExpandRounds))
        let wb = LXStamper.stampWorkblock(material: id, expandRounds: LXStamper.peeringExpandRounds)
        XCTAssertTrue(LXStamper.stampValid(stamp: stamp, targetCost: 4, workblock: wb))
    }

    func testCancellationStopsGeneration() {
        // A cost nobody reaches in a test, cancelled immediately.
        let result = LXStamper.generateStamp(material: Data(repeating: 0x01, count: 32),
                                             targetCost: 64,
                                             expandRounds: LXStamper.peeringExpandRounds,
                                             isCancelled: { true })
        XCTAssertNil(result, "a cancelled generation returns nil rather than spinning forever")
    }
}
