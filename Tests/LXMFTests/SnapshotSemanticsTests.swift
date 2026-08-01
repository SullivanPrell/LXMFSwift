import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/055`, step 5 — what a read of shared propagation state is *guaranteed to be*.
///
/// Encapsulation removed the unsynchronized write path. These pin the other half: that what comes
/// back is a coherent snapshot rather than a live view, and that holding it cannot reach back into
/// the router.
///
/// **Only one of these five is evidence for the lock** —
/// `testIteratingAMessageStoreSnapshotDuringConcurrentMutationCompletes`, which segfaults without
/// it. The other four are true of any value-typed property and would pass against the code this
/// change replaced; each says so on itself. They are regression guards for the *shape*, not proof
/// of the fix, and an earlier version of this file's header implied otherwise.
///
/// Python gets the iteration property by iterating `self.propagation_entries.copy()` rather than
/// the dictionary itself (`LXMRouter.py:1149`, `:1189`); the Swift accessor takes the copy for the
/// caller, because callers cannot be relied upon to do it.
final class SnapshotSemanticsTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_snapshot_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    private func makeStore() throws -> (LXMRouter, [Data]) {
        let router = LXMRouter(transport: Transport())
        try router.enablePropagation(storagePath: tempDir)
        router.setMessageStorageLimit(megabytes: 100)

        let destHash = Data(repeating: 0x11, count: LXMessage.destinationLength)
        var ids: [Data] = []
        for i in 0..<60 {
            let lxmf = destHash + Data((0..<40).map { UInt8(($0 &+ i) & 0xFF) }) + Data([UInt8(i & 0xFF)])
            let tid  = Hashes.fullHash(lxmf)
            router.addToMessageStore(lxmfData: lxmf, transientID: tid, stampValue: 5,
                                     stamp: Data(repeating: UInt8(i & 0xFF), count: LXStamper.stampSize))
            ids.append(tid)
        }
        return (router, ids)
    }

    /// **Observed red before the fix.** Against the stored `public var` this is a race on the live
    /// dictionary, and the whole suite took SIGSEGV — an unguarded read hitting a rehash is a
    /// crash, not a stale value. Recorded in task 1.2's notes with the ThreadSanitizer report.
    func testIteratingAMessageStoreSnapshotDuringConcurrentMutationCompletes() throws {
        let (router, ids) = try makeStore()

        let done = expectation(description: "snapshot iteration")
        let iterations = 400

        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 4) { w in
                for i in 0..<iterations {
                    if w == 0 {
                        // One snapshot, iterated to completion while others mutate the store.
                        let snapshot = router.propagationEntries
                        var bytes = 0
                        for (_, entry) in snapshot { bytes &+= entry.msgSize }
                        XCTAssertGreaterThanOrEqual(bytes, 0)

                        // The count cannot change under us: this is a value, not a view.
                        let n = snapshot.count
                        XCTAssertEqual(snapshot.count, n,
                                       "the snapshot changed size while it was being read — it is a live view, not a copy")
                    } else {
                        let tid = ids[(w &* 7 &+ i) % ids.count]
                        if (w &+ i) % 2 == 0 {
                            router.removeFromMessageStore(transientID: tid)
                        } else {
                            let lxmf = Data(repeating: UInt8((w &+ i) & 0xFF), count: 64)
                            router.addToMessageStore(lxmfData: Data(repeating: 0x11, count: LXMessage.destinationLength) + lxmf,
                                                     transientID: Hashes.fullHash(lxmf), stampValue: 1,
                                                     stamp: Data(repeating: 0x01, count: LXStamper.stampSize))
                        }
                    }
                }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 180)
    }

    /// **This would pass against the pre-fix stored `public var` too**, and saying otherwise would
    /// be claiming a proof this does not give. Swift's copy-on-write makes it true of any
    /// `Dictionary`-valued property, locked or not.
    ///
    /// It is here for a different regression: someone deciding the accessor should hand back the
    /// live storage — via `inout`, an `UnsafeMutablePointer`, or by making the store a class — at
    /// which point every other guarantee in this file collapses. The lock is proved by
    /// `testIteratingAMessageStoreSnapshotDuringConcurrentMutationCompletes`, which does segfault
    /// without it.
    func testMutatingAMessageStoreSnapshotDoesNotReachTheRouter() throws {
        let (router, ids) = try makeStore()
        let before = router.propagationEntries.count
        XCTAssertGreaterThan(before, 0, "precondition: the store is not empty")

        var snapshot = router.propagationEntries
        snapshot.removeAll()
        snapshot[Data(repeating: 0xAB, count: 32)] = PropagationEntry(
            destinationHash: Data(repeating: 0x11, count: LXMessage.destinationLength),
            filePath: "/tmp/none", received: 0, msgSize: 999, stampValue: 0)

        XCTAssertEqual(router.propagationEntries.count, before,
                       "mutating the returned collection changed the router's store — the accessor handed back a reference to live state")
        XCTAssertNotNil(router.propagationEntries[ids[0]],
                        "an entry the caller removed from its own copy disappeared from the router")
    }

    /// As above: true of any `Dictionary` property, and not evidence for the lock.
    func testMutatingAPeerTableSnapshotDoesNotReachTheRouter() throws {
        let router = LXMRouter(transport: Transport())
        try router.enablePropagation(storagePath: tempDir)
        for p in 0..<5 {
            router.addPeer(destinationHash: Data([UInt8(p)] + Data(repeating: 0xEE,
                                                                   count: LXMessage.destinationLength - 1)))
        }
        let before = router.peers.count
        XCTAssertEqual(before, 5)

        var snapshot = router.peers
        snapshot.removeAll()

        XCTAssertEqual(router.peers.count, before,
                       "the peer table is a reference, not a snapshot")
    }

    /// The limit of the guarantee, stated so nobody reads more into it than is there.
    ///
    /// A peer-table snapshot copies the *dictionary*. Its elements are `LXMPeer` references, and
    /// two snapshots taken at different times hand back the same objects — which is correct, and
    /// is why `LXMPeer`'s own properties had to be converted in the same change. A snapshot of a
    /// table of classes is not a deep copy and does not pretend to be one.
    func testAPeerTableSnapshotSharesItsPeerObjects() throws {
        let router = LXMRouter(transport: Transport())
        try router.enablePropagation(storagePath: tempDir)
        let hash = Data([0x01] + Data(repeating: 0xEE, count: LXMessage.destinationLength - 1))
        router.addPeer(destinationHash: hash)

        let first  = try XCTUnwrap(router.peers[hash])
        let second = try XCTUnwrap(router.peers[hash])
        XCTAssertTrue(first === second,
                      "peer identity is not preserved across reads — something is copying peers")

        first.seedStatistics(offered: 42)
        XCTAssertEqual(second.offered, 42,
                       "the two references disagree, so the snapshot deep-copied — which would silently discard writes")
    }

    /// The message store's elements are values, so the same is *not* true one level down.
    func testAMessageStoreSnapshotCopiesItsEntries() throws {
        let (router, ids) = try makeStore()
        var snapshot = try XCTUnwrap(router.propagationEntries[ids[0]])
        let original = snapshot.msgSize

        snapshot.msgSize = original + 1_000
        XCTAssertEqual(router.propagationEntries[ids[0]]?.msgSize, original,
                       """
                       mutating a copied `PropagationEntry` changed the stored one. It is a struct \
                       (`LXMPeer.swift:8`), which is what makes the store's snapshot safe all the \
                       way down; if it ever becomes a class, the accessor stops being enough.
                       """)
    }
}
