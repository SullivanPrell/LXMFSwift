import XCTest
@testable import LXMF
import ReticulumSwift

/// Concurrency stress test for the LXMRouter propagation-node collections hardened in
/// the 2026-07-19 deferred data-race pass (propagationEntries / peers /
/// peerDistributionQueue / validatedPeerLinks / clientPropagationMessages* — plus
/// LXMPeer's cross-object propagationEntries mutations routed through synchronized
/// router accessors) AND LXMPeer's OWN internal state (message queues + count caches +
/// sync state machine), hardened in the follow-up per-peer-lock pass.
///
/// The PN request handlers (handleOfferRequest / handleMessageGetRequest /
/// handleInboundPropagationResource) run on RNS link-callback threads concurrently
/// with the admin/driver methods (addPeer / removePeer / flushPeerDistributionQueue /
/// syncPeers / cleanMessageStore / savePeers / saveNodeStats). Pre-fix, the
/// propagationEntries Dictionary was read-modify-written (including in-place
/// force-unwrap value mutation from LXMPeer) with no lock — a crash under concurrency.
///
/// The original test kept a SINGLE serialized "driver" (worker 0) for the peer-touching
/// operations, because LXMPeer's own internal state (unhandledMessagesQueue /
/// handledMessagesQueue, the _hmCount/_umCount caches, and the sync state machine) was
/// not per-peer-locked. That constraint is now REMOVED: every worker drives
/// flush/sync/addPeer/removePeer/savePeers concurrently, so two threads can be inside
/// `peer.processQueues()` (both past the `!isEmpty` guard → `removeLast` on an empty
/// queue = crash) or `peer.sync()` / `peer.toBytes()` on the SAME peer object at once.
/// The per-peer NSLock must make all of that race- and crash-free.
///
/// A lock-order inversion or reentrant self-deadlock (holding the router `lock` across
/// a peer method that re-acquires it, or holding a peer's lock across a router accessor
/// that a second peer path re-enters) would TIME OUT; a torn/duplicate-key Dictionary
/// access or empty-queue `removeLast` would CRASH; an unsynchronized field would be a
/// TSan report. Passing under ThreadSanitizer (`swift test
/// -Xswiftc -sanitize=thread --filter LXMRouterPNConcurrencyTests`) proves none happen.
final class LXMRouterPNConcurrencyTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_pnconc_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    private final class DummyLinkID {}

    func testConcurrentPNCollectionsDoNotCrashOrRace() throws {
        let router = LXMRouter(transport: Transport())
        try router.enablePropagation(storagePath: tempDir)
        router.setMessageStorageLimit(megabytes: 100)

        // One shared delivery-destination hash so get-requests actually match entries.
        let destHash = Data(repeating: 0x11, count: LXMessage.destinationLength)

        // Pre-generate a pool of messages (some seeded up front, the rest added live).
        struct Msg { let lxmf: Data; let tid: Data; let stamp: Data }
        var pool: [Msg] = []
        for i in 0..<80 {
            let lxmf  = destHash + Data((0..<40).map { UInt8(($0 &+ i) & 0xFF) }) + Data([UInt8(i & 0xFF)])
            let stamp = Data(repeating: UInt8(i & 0xFF), count: LXStamper.stampSize)
            pool.append(Msg(lxmf: lxmf, tid: Hashes.fullHash(lxmf), stamp: stamp))
        }
        for m in pool.prefix(20) {
            router.addToMessageStore(lxmfData: m.lxmf, transientID: m.tid, stampValue: 5, stamp: m.stamp)
        }
        for p in 0..<8 {
            router.addPeer(destinationHash: Data([UInt8(p)] + Data(repeating: 0xEE, count: LXMessage.destinationLength - 1)))
        }
        let linkPool = (0..<8).map { _ in DummyLinkID() }
        let peerHashes = (0..<8).map { p in Data([UInt8(p)] + Data(repeating: 0xEE, count: LXMessage.destinationLength - 1)) }

        let done = expectation(description: "PN stress")
        let workers = 8
        let iterations = 1500

        // NO single-driver constraint: EVERY worker concurrently (a) drives a
        // peer-touching operation — flush/sync/addPeer/removePeer/savePeers, which mutate
        // per-peer internal state (queues + count caches + sync state machine) — AND
        // (b) hammers the ROUTER PN collections via the request handlers + message store.
        // Multiple workers therefore land inside the same peer object's
        // processQueues()/sync()/toBytes() at once; only the per-peer lock keeps that
        // from racing/crashing. The router-collection coverage of the original test is
        // retained by (b).
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                for i in 0..<iterations {
                    let m = pool[(w &* 7 &+ i) % pool.count]
                    let tid = m.tid

                    // (a) Peer-touching driver op — run by ALL workers (was worker-0 only).
                    switch (w &+ i) % 5 {
                    case 0: router.enqueueForPeerDistribution(transientID: tid); router.flushPeerDistributionQueue()
                    case 1: router.syncPeers()
                    case 2: router.addPeer(destinationHash: peerHashes[(w &+ i) % peerHashes.count])
                    case 3: if (w &+ i) % 9 == 0 { router.removePeer(destinationHash: peerHashes[(w &+ i) % peerHashes.count]) }
                    default: router.savePeers()
                    }

                    // (b) ROUTER-collection op — concurrent with every other worker's (a).
                    switch (w &* 3 &+ i) % 8 {
                    case 0: router.addToMessageStore(lxmfData: m.lxmf, transientID: tid, stampValue: 5, stamp: m.stamp)
                    case 1: _ = router.ingestPropagatedLXM(lxmfData: m.lxmf, stampValue: 5, stamp: m.stamp)
                    case 2: _ = router.handleMessageGetRequest(
                                data: .array([.array([.bytes(tid)]), .nil]), remoteDeliveryHash: destHash)
                    case 3: _ = router.handleMessageGetRequest(
                                data: .array([.nil, .array([.bytes(tid)])]), remoteDeliveryHash: destHash)
                    case 4: _ = router.handleOfferRequest(
                                data: .array([.bytes(Data([0x01])), .array([.bytes(tid)])]),
                                remoteIdentityHash: Data(repeating: 0x77, count: 16),
                                linkID: ObjectIdentifier(linkPool[(w &+ i) % linkPool.count]))
                    case 5: router.enqueueForPeerDistribution(transientID: tid)
                    case 6: router.saveNodeStats()
                    default: _ = router.messageStorageSize(); _ = router.getStampValue(transientID: tid)
                    }
                }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 120)
        _ = router.messageStorageSize()
    }
}
