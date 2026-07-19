import XCTest
@testable import LXMF
import ReticulumSwift

/// Concurrency stress test for the LXMRouter propagation-node collections hardened in
/// the 2026-07-19 deferred data-race pass (propagationEntries / peers /
/// peerDistributionQueue / validatedPeerLinks / clientPropagationMessages* — plus
/// LXMPeer's cross-object propagationEntries mutations routed through synchronized
/// router accessors).
///
/// The PN request handlers (handleOfferRequest / handleMessageGetRequest /
/// handleInboundPropagationResource) run on RNS link-callback threads concurrently
/// with the admin/driver methods (addPeer / removePeer / flushPeerDistributionQueue /
/// syncPeers / cleanMessageStore / savePeers / saveNodeStats). Pre-fix, the
/// propagationEntries Dictionary was read-modify-written (including in-place
/// force-unwrap value mutation from LXMPeer) with no lock — a crash under concurrency.
///
/// A lock-order inversion or reentrant self-deadlock (holding the router `lock` across
/// a peer method that re-acquires it) would TIME OUT; a torn/duplicate-key Dictionary
/// access would CRASH. Passing under ThreadSanitizer (`swift test
/// -Xswiftc -sanitize=thread --filter LXMRouterPNConcurrencyTests`) proves neither
/// happens on these paths.
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

        // Threading model mirrors production: a SINGLE "driver" thread (worker 0) owns
        // the peer-touching operations (flush/sync/addPeer/removePeer/savePeers — these
        // mutate per-peer internal state, which is intentionally not per-peer-locked),
        // while all other workers hammer the ROUTER PN collections via the request
        // handlers + message store. This exercises the target of the fix: concurrent
        // access to propagationEntries / peers / peerDistributionQueue /
        // validatedPeerLinks / clientPropagationMessages* from the link-callback threads
        // vs the driver.
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                for i in 0..<iterations {
                    let m = pool[(w &* 7 &+ i) % pool.count]
                    let tid = m.tid
                    if w == 0 {
                        // Serial driver: peer-touching operations.
                        switch i % 5 {
                        case 0: router.enqueueForPeerDistribution(transientID: tid); router.flushPeerDistributionQueue()
                        case 1: router.syncPeers()
                        case 2: router.addPeer(destinationHash: peerHashes[i % peerHashes.count])
                        case 3: if i % 9 == 0 { router.removePeer(destinationHash: peerHashes[i % peerHashes.count]) }
                        default: router.savePeers()
                        }
                        continue
                    }
                    // Link-callback / client threads: ROUTER-collection operations only.
                    switch (w &+ i) % 8 {
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
        wait(for: [done], timeout: 90)
        _ = router.messageStorageSize()
    }
}
