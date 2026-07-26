import XCTest
import ReticulumSwift
@testable import LXMF

/// Parity tests for LXMF 1.1.0 inbound message-resource tracking
/// (Python commit d909619) and the `propagation_transfer_size` field.
final class InboundResourceTrackingTests: XCTestCase {

    private func makeRouter() -> LXMRouter {
        LXMRouter(transport: Transport())
    }

    // MARK: - Registry lifecycle

    func testInboundCountStartsAtZero() {
        XCTAssertEqual(makeRouter().inboundCount(), 0)
        XCTAssertTrue(makeRouter().inboundResources().isEmpty)
    }

    func testCancelUnknownResourceReturnsFalse() {
        let router = makeRouter()
        XCTAssertFalse(router.cancelInbound(resourceHash: Data(repeating: 0xAB, count: 32)),
                       "Python logs a warning and returns False for an unknown resource hash")
    }

    func testCancelAllInboundWithNothingRunningReturnsZero() {
        XCTAssertEqual(makeRouter().cancelAllInbound(), 0)
    }

    func testJobResourceIntervalMatchesPython() {
        XCTAssertEqual(LXMRouter.jobResourceInterval, 2,
                       "Python LXMRouter.JOB_RESOURCE_INTERVAL = 2")
    }

    /// The reap must not disturb an empty registry, and must be safe to call
    /// repeatedly (the job loop calls it every other tick forever).
    func testCleanResourceTrackingIsIdempotent() {
        let router = makeRouter()
        router.cleanResourceTracking()
        router.cleanResourceTracking()
        XCTAssertEqual(router.inboundCount(), 0)
    }

    // MARK: - propagation_transfer_size

    func testPropagationTransferSizeStartsNil() {
        XCTAssertNil(makeRouter().propagationTransferSize,
                     "Python: self.propagation_transfer_size = None")
    }

    func testCancelPropagationRequestsClearsTransferSize() {
        let router = makeRouter()
        router.propagationTransferSize = 4096
        router.cancelPropagationNodeRequests()
        XCTAssertNil(router.propagationTransferSize,
                     "a cancelled sync must not leave a stale byte count for the UI to render")
    }

    /// Python's `message_get_progress` publishes the response size *while the
    /// transfer runs*, which is the only time a progress display can use it. The
    /// size has to come off a receipt that is genuinely mid-transfer, so this
    /// drives a real oversized request response over a link and feeds the router
    /// the progress callbacks that response produces.
    func testMessageGetProgressPublishesStateProgressAndSize() throws {
        let router = makeRouter()
        // Incompressible, so the response is large enough on the wire to come
        // back as a Resource rather than a single packet — only the Resource
        // path produces the progress callbacks under test.
        let responseBytes = Data((0 ..< 8192).map { _ in UInt8.random(in: 0 ... 255) })
        let (_, _, aLink, _) = try establishLoopbackLinks(requestHandler: { _ in responseBytes })

        let progressed = expectation(description: "progress observed with a size")
        progressed.assertForOverFulfill = false
        _ = try aLink.request(
            path: "/messages",
            data: Data([0x01]),
            progressCallback: { progress, receipt in
                router.messageGetProgress(progress, receipt: receipt)
                if router.propagationTransferSize != nil { progressed.fulfill() }
            }
        )
        wait(for: [progressed], timeout: 5.0)

        XCTAssertEqual(router.propagationTransferState, .receiving,
                       "Python sets PR_RECEIVING from message_get_progress")
        XCTAssertGreaterThan(router.propagationTransferProgress, 0.0)
        let size = try XCTUnwrap(router.propagationTransferSize,
                                 "response size was never published mid-transfer")
        XCTAssertGreaterThanOrEqual(size, responseBytes.count,
                                    "published size should be the advertised transfer size")
    }

    /// Python guards the assignment with `if request_receipt.response_size:`, so a
    /// receipt with no size yet must not clear a size already published.
    func testMessageGetProgressDoesNotClobberKnownSizeWithMissingSize() throws {
        let router = makeRouter()
        let (_, _, aLink, _) = try establishLoopbackLinks()
        router.propagationTransferSize = 8192

        // A receipt that has not begun receiving a resource has no response size.
        let receipt = try aLink.request(path: "/test", data: Data([0x01]))
        XCTAssertNil(receipt.responseSize)
        router.messageGetProgress(0.5, receipt: receipt)

        XCTAssertEqual(router.propagationTransferSize, 8192)
        XCTAssertEqual(router.propagationTransferProgress, 0.5, accuracy: 0.0001)
    }

    func testAcknowledgeSyncCompletionClearsTransferSize() {
        let router = makeRouter()
        router.propagationTransferState = .done
        router.propagationTransferProgress = 1.0
        router.propagationTransferSize = 65536
        router.wantsDownloadOnPathAvailableFrom = Data(repeating: 0x11, count: 16)

        router.acknowledgeSyncCompletion()

        XCTAssertEqual(router.propagationTransferState, .idle)
        XCTAssertEqual(router.propagationTransferProgress, 0.0)
        XCTAssertNil(router.propagationTransferSize,
                     "a finished sync must not leave its byte count visible to the next one")
        XCTAssertNil(router.wantsDownloadOnPathAvailableFrom)
    }

    /// A failure stays visible until explicitly acknowledged — Python only resets
    /// the state when `reset_state` is set or the state is not a failure code.
    func testAcknowledgeSyncCompletionLeavesFailureStateUnlessReset() {
        let router = makeRouter()
        router.propagationTransferState = .failed
        router.acknowledgeSyncCompletion()
        XCTAssertEqual(router.propagationTransferState, .failed)

        router.acknowledgeSyncCompletion(resetState: true)
        XCTAssertEqual(router.propagationTransferState, .idle)
    }

    func testAcknowledgeSyncCompletionHonoursExplicitFailureState() {
        let router = makeRouter()
        router.propagationTransferState = .done
        router.acknowledgeSyncCompletion(failureState: .failed)
        XCTAssertEqual(router.propagationTransferState, .failed)
    }

    // MARK: - Registry keying (real resources over a real link)

    /// The registry is keyed by `resource.hash`, exactly as Python does
    /// (`incoming_delivery_resources[resource.hash] = resource`). That only works
    /// if the hash is already populated when the resource-started callback fires.
    ///
    /// It was not: ReticulumSwift used to call the callback before parsing the
    /// advertisement, so every transfer arrived carrying the empty initial
    /// `Data()`. This test drives two concurrent inbound resources over a real
    /// link and checks they occupy two distinct 32-byte keys — with the old
    /// ordering both collapse onto one empty key and the second silently evicts
    /// the first.
    func testConcurrentInboundResourcesGetDistinctRegistryKeys() throws {
        let (router, aLink, bLink) = try establishRouterDeliveryLink()

        let started = expectation(description: "two resource starts")
        started.expectedFulfillmentCount = 2
        let routerHook = bLink.onResourceStarted
        bLink.onResourceStarted = { transfer in
            routerHook?(transfer)
            started.fulfill()
        }

        let first  = ResourceTransfer(link: aLink)
        let second = ResourceTransfer(link: aLink)
        try first.send(payload: Data(repeating: 0xA1, count: 4096))
        try second.send(payload: Data(repeating: 0xB2, count: 4096))
        wait(for: [started], timeout: 5.0)

        // Concluded entries stay in the registry until the job loop reaps them,
        // so this count is stable regardless of how fast the transfers finish.
        let keys = router.inboundRegistryKeys()
        XCTAssertEqual(keys.count, 2,
                       "two concurrent transfers collapsed onto one registry key")
        XCTAssertTrue(keys.allSatisfy { !$0.isEmpty },
                      "registry keyed by an empty hash: \(keys.map(\.count))")
    }

    /// `cancelInbound` takes the hash a caller read back off a listed transfer, so
    /// the key it was filed under has to be that same hash.
    func testCancelInboundMatchesTheHashSeenOnTheTransfer() throws {
        let (router, aLink, bLink) = try establishRouterDeliveryLink()

        let cancelled = expectation(description: "cancel resolved at start time")
        let routerHook = bLink.onResourceStarted
        var cancelResult = false
        var observedHash = Data()
        bLink.onResourceStarted = { transfer in
            routerHook?(transfer)
            // The transfer is registered and still running at this point, so a
            // lookup by its own hash must find and cancel it.
            observedHash = transfer.resourceHash
            cancelResult = router.cancelInbound(resourceHash: observedHash)
            cancelled.fulfill()
        }

        let rt = ResourceTransfer(link: aLink)
        try rt.send(payload: Data(repeating: 0xC3, count: 4096))
        wait(for: [cancelled], timeout: 5.0)

        XCTAssertEqual(observedHash.count, 32,
                       "resource hash was not populated when the transfer was registered")
        XCTAssertTrue(cancelResult,
                      "cancelInbound could not find a transfer by the hash it was filed under")
    }

    // MARK: - Harness

    /// A delivery link into a router, so the router's own
    /// `onResourceStarted` wiring is what registers inbound transfers.
    private func establishRouterDeliveryLink() throws -> (LXMRouter, Link, Link) {
        let (aT, bT, aLink, bLink) = try establishLoopbackLinks(
            configure: { bTransport, bIdentity in
                let router = LXMRouter(transport: bTransport)
                let delivery = try router.register(identity: bIdentity, transport: bTransport)
                return (router, delivery)
            }
        )
        _ = (aT, bT)
        return (routerUnderTest!, aLink, bLink)
    }

    private var routerUnderTest: LXMRouter?

    private func establishLoopbackLinks(
        configure: ((Transport, Identity) throws -> (LXMRouter, Destination))? = nil,
        requestHandler: ((Data?) -> Data?)? = nil
    ) throws -> (Transport, Transport, Link, Link) {
        let aT = Transport(); let bT = Transport()
        let bId = Identity()
        bT.ownerIdentity = bId

        let bDest: Destination
        if let configure {
            let (router, delivery) = try configure(bT, bId)
            routerUnderTest = router
            bDest = delivery
        } else {
            bDest = try Destination(identity: bId, direction: .in, kind: .single,
                                    appName: "lxmf", aspects: ["delivery"])
            bT.register(destination: bDest)
        }
        retainedTransports = [aT, bT]

        if let requestHandler {
            bDest.registerRequestHandler(path: "/messages", allow: .all) { _, data, _, _, _ in
                requestHandler(data)
            }
        }

        let aI = TrackingLoopIface(name: "A"); let bI = TrackingLoopIface(name: "B")
        aI.paired = bI; bI.paired = aI
        aT.register(interface: aI); bT.register(interface: bI)

        let aE = expectation(description: "a"); let bE = expectation(description: "b")
        aT.onLinkEstablished = { _ in aE.fulfill() }
        let existingB = bT.onLinkEstablished
        bT.onLinkEstablished = { link in existingB?(link); bE.fulfill() }

        let aLink = try Link.initiate(destination: bDest, transport: aT)
        wait(for: [aE, bE], timeout: 2.0)
        let bLink = try XCTUnwrap(bT.links[aLink.linkID!])
        return (aT, bT, aLink, bLink)
    }

    /// Keeps the transports alive for the duration of the test; a Transport that
    /// deallocates mid-transfer takes its links and interfaces down with it.
    private var retainedTransports: [Transport] = []
}

// MARK: - Loopback interface

private final class TrackingLoopIface: Interface {
    let name: String
    var bitrate: Int = 1_000_000
    var isOnline: Bool = true
    var inboundHandler: ((Packet, any Interface) -> Void)?
    weak var paired: TrackingLoopIface?

    init(name: String) { self.name = name }
    func start() throws { isOnline = true }
    func stop() { isOnline = false }

    func send(_ packet: Packet) throws {
        let raw = try packet.pack()
        let copy = try Packet.unpack(raw)
        paired?.inboundHandler?(copy, paired!)
    }
}
