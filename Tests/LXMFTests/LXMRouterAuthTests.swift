import XCTest
import ReticulumSwift
@testable import LXMF

/// Tests for LXMRouter authentication and allow/disallow lists.
///
/// Python reference (LXMRouter.py):
///   router.set_authentication(required=True)  → enable auth requirement
///   router.requires_authentication()          → current setting
///   router.allow(identity_hash)               → whitelist a hash
///   router.disallow(identity_hash)            → remove from whitelist
final class LXMRouterAuthTests: XCTestCase {

    private func makeRouter() -> LXMRouter {
        LXMRouter(transport: Transport())
    }

    // MARK: - Authentication defaults

    func testAuthNotRequiredByDefault() {
        let router = makeRouter()
        XCTAssertFalse(router.requiresAuthentication(),
                       "authentication must not be required by default")
    }

    // MARK: - set_authentication / requires_authentication

    func testSetAuthenticationTrue() {
        let router = makeRouter()
        router.setAuthentication(required: true)
        XCTAssertTrue(router.requiresAuthentication(),
                      "setAuthentication(required: true) must make requiresAuthentication() return true")
    }

    func testSetAuthenticationFalse() {
        let router = makeRouter()
        router.setAuthentication(required: true)
        router.setAuthentication(required: false)
        XCTAssertFalse(router.requiresAuthentication(),
                       "setAuthentication(required: false) must disable auth requirement")
    }

    func testSetAuthenticationIsIdempotent() {
        let router = makeRouter()
        router.setAuthentication(required: true)
        router.setAuthentication(required: true)
        XCTAssertTrue(router.requiresAuthentication())
    }

    // MARK: - allow / disallow

    func testAllowAddsToAllowedList() {
        let router = makeRouter()
        let hash = Data(repeating: 0x01, count: 16)
        router.allow(identityHash: hash)
        XCTAssertTrue(router.isAllowed(identityHash: hash),
                      "allow() must add the hash to the allowed list")
    }

    func testDisallowRemovesFromAllowedList() {
        let router = makeRouter()
        let hash = Data(repeating: 0x02, count: 16)
        router.allow(identityHash: hash)
        router.disallow(identityHash: hash)
        XCTAssertFalse(router.isAllowed(identityHash: hash),
                       "disallow() must remove the hash from the allowed list")
    }

    func testDisallowUnknownHashIsNoOp() {
        let router = makeRouter()
        let hash = Data(repeating: 0x03, count: 16)
        router.disallow(identityHash: hash)   // must not crash
        XCTAssertFalse(router.isAllowed(identityHash: hash))
    }

    func testAllowMultipleHashes() {
        let router = makeRouter()
        let hashes = (0..<5).map { Data(repeating: UInt8($0 + 1), count: 16) }
        hashes.forEach { router.allow(identityHash: $0) }
        for h in hashes {
            XCTAssertTrue(router.isAllowed(identityHash: h))
        }
    }

    func testIsAllowedReturnsFalseForUnknownHash() {
        let router = makeRouter()
        let unknown = Data(repeating: 0xFF, count: 16)
        XCTAssertFalse(router.isAllowed(identityHash: unknown))
    }
}
