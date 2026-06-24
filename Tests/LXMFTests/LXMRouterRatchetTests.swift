import XCTest
import ReticulumSwift
@testable import LXMF

/// Tests for LXMRouter.enforceRatchets.
/// Python reference (LXMRouter.py lines 91, 139, 335–345):
///   LXMRouter.__init__(enforce_ratchets=False)
///   delivery_destination.enable_ratchets(path)
///   if self.enforce_ratchets: delivery_destination.enforce_ratchets()
final class LXMRouterRatchetTests: XCTestCase {

    private func makeRouter() -> LXMRouter {
        LXMRouter(transport: Transport())
    }

    // MARK: - enforceRatchets property

    func testEnforceRatchetsDefaultsFalse() {
        XCTAssertFalse(makeRouter().enforceRatchets,
                       "enforceRatchets must default to false (mirrors Python enforce_ratchets=False)")
    }

    func testEnforceRatchetsCanBeSetToTrue() {
        let router = makeRouter()
        router.enforceRatchets = true
        XCTAssertTrue(router.enforceRatchets)
    }

    func testEnforceRatchetsCanBeReset() {
        let router = makeRouter()
        router.enforceRatchets = true
        router.enforceRatchets = false
        XCTAssertFalse(router.enforceRatchets)
    }

    // MARK: - register() ratchet wiring

    func testRegisterWithStoragePathEnablesRatchetsOnDeliveryDestination() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let router = makeRouter()
        router.storagePath = tmp.path
        let identity = Identity()
        let delivery = try router.register(identity: identity, transport: Transport())
        XCTAssertTrue(delivery.ratchetsEnabled,
                      "register() must call enableRatchets() on the delivery destination when storagePath is set")
    }

    func testRegisterWithoutStoragePathDoesNotEnableRatchets() throws {
        let router = makeRouter()
        let identity = Identity()
        let delivery = try router.register(identity: identity, transport: Transport())
        XCTAssertFalse(delivery.ratchetsEnabled,
                       "register() must not enable ratchets when storagePath is nil")
    }

    func testRegisterWithEnforceRatchetsAndStoragePathEnforcesRatchets() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let router = makeRouter()
        router.storagePath = tmp.path
        router.enforceRatchets = true
        let identity = Identity()
        let delivery = try router.register(identity: identity, transport: Transport())
        XCTAssertTrue(delivery.ratchetsEnforced,
                      "register() must call enforceRatchets() when enforceRatchets=true and storagePath is set")
    }

    func testRegisterWithEnforceRatchetsButNoStoragePathDoesNotEnforce() throws {
        // Without storagePath, enableRatchets() is never called, so
        // enforceRatchets() is a no-op (ratchetsEnabled guard in Destination).
        let router = makeRouter()
        router.enforceRatchets = true
        let identity = Identity()
        let delivery = try router.register(identity: identity, transport: Transport())
        XCTAssertFalse(delivery.ratchetsEnforced,
                       "enforceRatchets without storagePath must not set ratchetsEnforced (ratchets never enabled)")
    }

    func testRegisterWithStoragePathButEnforceRatchetsFalseDoesNotEnforce() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let router = makeRouter()
        router.storagePath = tmp.path
        router.enforceRatchets = false
        let identity = Identity()
        let delivery = try router.register(identity: identity, transport: Transport())
        XCTAssertTrue(delivery.ratchetsEnabled, "ratchets must be enabled (storagePath set)")
        XCTAssertFalse(delivery.ratchetsEnforced, "ratchets must not be enforced when enforceRatchets=false")
    }
}
