import XCTest
import ReticulumSwift
@testable import LXMF

/// Tests for the missing client-side API on LXMRouter:
///   - prioritise / unprioritise / isPrioritised
///   - enforceStamps / ignoreStamps / isEnforcingStamps
///   - ignoreDestination / unignoreDestination / isIgnoringDestination
///
/// Python reference (LXMRouter.py):
///   router.prioritise(destination_hash)
///   router.unprioritise(destination_hash)
///   router.enforce_stamps()
///   router.ignore_stamps()
///   router.ignore(destination_hash)
///   router.unignore(destination_hash)
final class LXMRouterMissingAPITests: XCTestCase {

    private func makeRouter() -> LXMRouter {
        LXMRouter(transport: Transport())
    }

    private func makeHash(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 16)
    }

    // MARK: - prioritise / isPrioritised

    func testPrioritiseAddsHash() {
        let router = makeRouter()
        let hash = makeHash(0x01)
        router.prioritise(destinationHash: hash)
        XCTAssertTrue(router.isPrioritised(destinationHash: hash),
                      "isPrioritised must return true after prioritise()")
    }

    func testPrioritiseIsIdempotent() {
        let router = makeRouter()
        let hash = makeHash(0x02)
        router.prioritise(destinationHash: hash)
        router.prioritise(destinationHash: hash)
        // Verify only one entry exists by unprioritising once and confirming it's gone
        router.unprioritise(destinationHash: hash)
        XCTAssertFalse(router.isPrioritised(destinationHash: hash),
                       "Idempotent prioritise: a single unprioritise must fully remove the hash")
    }

    func testUnprioritiseRemovesHash() {
        let router = makeRouter()
        let hash = makeHash(0x03)
        router.prioritise(destinationHash: hash)
        router.unprioritise(destinationHash: hash)
        XCTAssertFalse(router.isPrioritised(destinationHash: hash),
                       "isPrioritised must return false after unprioritise()")
    }

    func testUnprioritiseOnUnknownHashIsNoOp() {
        let router = makeRouter()
        let hash = makeHash(0x04)
        // Should not crash
        router.unprioritise(destinationHash: hash)
        XCTAssertFalse(router.isPrioritised(destinationHash: hash))
    }

    func testMultipleDifferentHashesCanBePrioritisedIndependently() {
        let router = makeRouter()
        let hash1 = makeHash(0x0A)
        let hash2 = makeHash(0x0B)
        let hash3 = makeHash(0x0C)
        router.prioritise(destinationHash: hash1)
        router.prioritise(destinationHash: hash2)
        router.prioritise(destinationHash: hash3)
        XCTAssertTrue(router.isPrioritised(destinationHash: hash1))
        XCTAssertTrue(router.isPrioritised(destinationHash: hash2))
        XCTAssertTrue(router.isPrioritised(destinationHash: hash3))
        router.unprioritise(destinationHash: hash2)
        XCTAssertTrue(router.isPrioritised(destinationHash: hash1))
        XCTAssertFalse(router.isPrioritised(destinationHash: hash2))
        XCTAssertTrue(router.isPrioritised(destinationHash: hash3))
    }

    func testIsPrioritisedDefaultsFalse() {
        let router = makeRouter()
        XCTAssertFalse(router.isPrioritised(destinationHash: makeHash(0xFF)),
                       "No hash should be prioritised by default")
    }

    // MARK: - enforceStamps / ignoreStamps / isEnforcingStamps

    func testIsEnforcingStampsDefaultsFalse() {
        let router = makeRouter()
        XCTAssertFalse(router.isEnforcingStamps(),
                       "stamp enforcement must be disabled by default")
    }

    func testEnforceStampsSetsTrue() {
        let router = makeRouter()
        router.enforceStamps()
        XCTAssertTrue(router.isEnforcingStamps(),
                      "isEnforcingStamps must return true after enforceStamps()")
    }

    func testIgnoreStampsSetsFalse() {
        let router = makeRouter()
        router.enforceStamps()
        router.ignoreStamps()
        XCTAssertFalse(router.isEnforcingStamps(),
                       "isEnforcingStamps must return false after ignoreStamps()")
    }

    func testEnforceStampsIsIdempotent() {
        let router = makeRouter()
        router.enforceStamps()
        router.enforceStamps()
        XCTAssertTrue(router.isEnforcingStamps())
    }

    // MARK: - ignoreDestination / unignoreDestination / isIgnoringDestination

    func testIgnoreDestinationAddsHash() {
        let router = makeRouter()
        let hash = makeHash(0x10)
        router.ignoreDestination(destinationHash: hash)
        XCTAssertTrue(router.isIgnoringDestination(destinationHash: hash),
                      "isIgnoringDestination must return true after ignoreDestination()")
    }

    func testIgnoreDestinationIsIdempotent() {
        let router = makeRouter()
        let hash = makeHash(0x11)
        router.ignoreDestination(destinationHash: hash)
        router.ignoreDestination(destinationHash: hash)
        // A single unignore should fully remove it
        router.unignoreDestination(destinationHash: hash)
        XCTAssertFalse(router.isIgnoringDestination(destinationHash: hash),
                       "Idempotent ignoreDestination: a single unignore must fully remove the hash")
    }

    func testUnignoreDestinationRemovesHash() {
        let router = makeRouter()
        let hash = makeHash(0x12)
        router.ignoreDestination(destinationHash: hash)
        router.unignoreDestination(destinationHash: hash)
        XCTAssertFalse(router.isIgnoringDestination(destinationHash: hash),
                       "isIgnoringDestination must return false after unignoreDestination()")
    }

    func testUnignoreDestinationOnUnknownHashIsNoOp() {
        let router = makeRouter()
        let hash = makeHash(0x13)
        // Should not crash
        router.unignoreDestination(destinationHash: hash)
        XCTAssertFalse(router.isIgnoringDestination(destinationHash: hash))
    }

    func testIsIgnoringDestinationDefaultsFalse() {
        let router = makeRouter()
        XCTAssertFalse(router.isIgnoringDestination(destinationHash: makeHash(0xFE)),
                       "No destination should be ignored by default")
    }
}
