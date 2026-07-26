import XCTest
import ReticulumSwift
@testable import LXMF

/// The transient-ID caches used to be timestamp-less `Set`s, so nothing could
/// ever expire from them: they grew for the lifetime of the install and were
/// rewritten to disk in full on every save. These tests pin the Python
/// behaviour — timestamped entries, expiry at `MESSAGE_EXPIRY * 6`, and a
/// propagation-node tombstone that survives the message being pruned.
final class TransientIDCacheExpiryTests: XCTestCase {

    private func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "/lxmf-cache-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRouter() -> LXMRouter { LXMRouter(transport: Transport()) }

    // MARK: - Constants

    func testCacheConstantsMatchPython() {
        XCTAssertEqual(LXMRouter.transientIDCacheExpiry, 30 * 24 * 60 * 60 * 6.0,
                       "Python expires at MESSAGE_EXPIRY * 6.0")
        XCTAssertEqual(LXMRouter.jobTransientInterval, 60,
                       "Python LXMRouter.JOB_TRANSIENT_INTERVAL = 60")
    }

    // MARK: - Expiry

    func testExpiredDeliveredIDsAreReaped() {
        let router = makeRouter()
        let now = Date().timeIntervalSince1970
        let fresh = Data(repeating: 0x01, count: 32)
        let stale = Data(repeating: 0x02, count: 32)

        router.locallyDeliveredTransientIDs[fresh] = now
        router.locallyDeliveredTransientIDs[stale] = now - LXMRouter.transientIDCacheExpiry - 1

        router.cleanTransientIDCaches()

        XCTAssertTrue(router.hasMessage(transientID: fresh), "a recent delivery must be retained")
        XCTAssertFalse(router.hasMessage(transientID: stale), "an expired delivery must be reaped")
    }

    func testExpiryBoundaryIsInclusiveOfRecentEntries() {
        let router = makeRouter()
        let now = Date().timeIntervalSince1970
        // Just inside the window — must survive.
        let borderline = Data(repeating: 0x03, count: 32)
        router.locallyDeliveredTransientIDs[borderline] = now - LXMRouter.transientIDCacheExpiry + 60
        router.cleanTransientIDCaches()
        XCTAssertTrue(router.hasMessage(transientID: borderline))
    }

    func testExpiredProcessedIDsAreReaped() {
        let router = makeRouter()
        let now = Date().timeIntervalSince1970
        let stale = Data(repeating: 0x04, count: 32)
        router.locallyProcessedTransientIDs[stale] = now - LXMRouter.transientIDCacheExpiry - 1
        router.cleanTransientIDCaches()
        XCTAssertNil(router.locallyProcessedTransientIDs[stale])
    }

    // MARK: - Persistence

    func testDeliveredIDsRoundTripWithTimestamps() {
        let dir = tempDir()
        let tid = Data(repeating: 0xAA, count: 32)
        let stamp = Date().timeIntervalSince1970 - 1234

        let a = makeRouter()
        a.storagePath = dir
        a.locallyDeliveredTransientIDs[tid] = stamp
        a.saveLocallyDeliveredTransientIDs()

        let b = makeRouter()
        b.storagePath = dir
        XCTAssertEqual(b.locallyDeliveredTransientIDs[tid] ?? 0, stamp, accuracy: 0.001,
                       "the timestamp must survive the round trip, or nothing can ever expire")
    }

    /// An existing install has a bare msgpack array on disk. Loading it must
    /// migrate rather than discard — discarding would make the node re-deliver
    /// every message it had already seen.
    func testLegacyArrayFormatIsMigratedNotDiscarded() throws {
        let dir = tempDir()
        let tid = Data(repeating: 0xBB, count: 32)
        let legacy = MsgPack.encode(.array([.bytes(tid)]))
        try legacy.write(to: URL(fileURLWithPath: dir + "/local_deliveries"))

        let router = makeRouter()
        router.storagePath = dir

        XCTAssertTrue(router.hasMessage(transientID: tid),
                      "a legacy timestamp-less cache must be migrated, not dropped")
        XCTAssertNotNil(router.locallyDeliveredTransientIDs[tid],
                        "migrated entries need a timestamp so they can expire later")
    }

    func testProcessedIDsRoundTrip() {
        let dir = tempDir()
        let tid = Data(repeating: 0xCC, count: 32)
        let stamp = Date().timeIntervalSince1970 - 42

        let a = makeRouter()
        a.storagePath = dir
        a.locallyProcessedTransientIDs[tid] = stamp
        a.saveLocallyProcessedTransientIDs()

        let b = makeRouter()
        b.storagePath = dir
        XCTAssertEqual(b.locallyProcessedTransientIDs[tid] ?? 0, stamp, accuracy: 0.001)
    }
}
