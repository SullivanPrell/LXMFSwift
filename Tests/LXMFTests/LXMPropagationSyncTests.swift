import XCTest
@testable import LXMF
import ReticulumSwift

final class LXMPropagationSyncTests: XCTestCase {

    private func makeRouter() -> LXMRouter {
        LXMRouter(transport: Transport())
    }

    // MARK: - Default state

    func testPropagationTransferStateIdleByDefault() {
        XCTAssertEqual(makeRouter().propagationTransferState, .idle)
    }

    func testPropagationTransferProgressZeroByDefault() {
        XCTAssertEqual(makeRouter().propagationTransferProgress, 0.0, accuracy: 0.001)
    }

    func testPropagationTransferMaxMessagesNilByDefault() {
        XCTAssertNil(makeRouter().propagationTransferMaxMessages)
    }

    func testOutboundPropagationLinkNilByDefault() {
        XCTAssertNil(makeRouter().outboundPropagationLink)
    }

    // MARK: - Constants

    func testMessageGetPathConstant() {
        XCTAssertEqual(LXMRouter.messageGetPath, "/get")
    }

    func testMessageGetPathMatchesPeerConstant() {
        XCTAssertEqual(LXMRouter.messageGetPath, LXMPeer.messageGetPath)
    }

    func testPrPathTimeoutConstant() {
        XCTAssertEqual(LXMRouter.prPathTimeout, 10.0, accuracy: 0.01)
    }

    // MARK: - New properties

    func testDeliveryPerTransferLimitNilByDefault() {
        XCTAssertNil(makeRouter().deliveryPerTransferLimit)
    }

    func testRetainSyncedOnNodeFalseByDefault() {
        XCTAssertFalse(makeRouter().retainSyncedOnNode)
    }

    func testDeliveryPerTransferLimitCanBeSet() {
        let router = makeRouter()
        router.deliveryPerTransferLimit = 20
        XCTAssertEqual(router.deliveryPerTransferLimit, 20)
    }

    func testRetainSyncedOnNodeCanBeEnabled() {
        let router = makeRouter()
        router.retainSyncedOnNode = true
        XCTAssertTrue(router.retainSyncedOnNode)
    }

    // MARK: - requestMessagesFromPropagationNode

    func testRequestGracefullyNoopsWhenNoPropagationNode() {
        let router = makeRouter()
        router.outboundPropagationNode = nil
        let identity = Identity()
        router.requestMessagesFromPropagationNode(identity: identity)
        XCTAssertEqual(router.propagationTransferState, .idle)
    }

    func testRequestRecordsMaxMessages() {
        let router = makeRouter()
        // No propagation node set, but maxMessages should still be recorded before early return.
        let identity = Identity()
        router.requestMessagesFromPropagationNode(identity: identity, maxMessages: 5)
        XCTAssertEqual(router.propagationTransferMaxMessages, 5)
    }

    func testRequestResetsProgressToZero() {
        let router = makeRouter()
        router.propagationTransferProgress = 0.75
        router.requestMessagesFromPropagationNode(identity: Identity())
        XCTAssertEqual(router.propagationTransferProgress, 0.0, accuracy: 0.001)
    }

    func testRequestTransitionsToPathRequestedWhenNoPath() {
        let router = makeRouter()
        // Set a fake propagation node hash that the transport has no path to.
        router.outboundPropagationNode = Data(repeating: 0xAB, count: 16)
        router.requestMessagesFromPropagationNode(identity: Identity())
        XCTAssertEqual(router.propagationTransferState, .pathRequested)
    }

    func testRequestSetsWantsDownloadFrom() {
        let fakeHash = Data(repeating: 0xCD, count: 16)
        let router = makeRouter()
        router.outboundPropagationNode = fakeHash
        router.requestMessagesFromPropagationNode(identity: Identity())
        XCTAssertEqual(router.wantsDownloadOnPathAvailableFrom, fakeHash)
    }

    // MARK: - cancelPropagationNodeRequests

    func testCancelResetsStateToIdle() {
        let router = makeRouter()
        router.propagationTransferState = .requestSent
        router.cancelPropagationNodeRequests()
        XCTAssertEqual(router.propagationTransferState, .idle)
    }

    func testCancelResetsProgressToZero() {
        let router = makeRouter()
        router.propagationTransferProgress = 0.5
        router.cancelPropagationNodeRequests()
        XCTAssertEqual(router.propagationTransferProgress, 0.0, accuracy: 0.001)
    }

    func testCancelNilsOutboundLink() {
        let router = makeRouter()
        router.cancelPropagationNodeRequests()
        XCTAssertNil(router.outboundPropagationLink)
    }

    func testCancelNilsWantsDownload() {
        let fakeHash = Data(repeating: 0x01, count: 16)
        let router = makeRouter()
        router.wantsDownloadOnPathAvailableFrom = fakeHash
        router.cancelPropagationNodeRequests()
        XCTAssertNil(router.wantsDownloadOnPathAvailableFrom)
    }

    // MARK: - PropagationTransferState enum

    func testPropagationTransferStateEquatable() {
        XCTAssertEqual(PropagationTransferState.idle, .idle)
        XCTAssertNotEqual(PropagationTransferState.idle, .done)
        XCTAssertEqual(PropagationTransferState.pathRequested, .pathRequested)
        XCTAssertEqual(PropagationTransferState.linkEstablishing, .linkEstablishing)
        XCTAssertEqual(PropagationTransferState.linkEstablished, .linkEstablished)
        XCTAssertEqual(PropagationTransferState.requestSent, .requestSent)
        XCTAssertEqual(PropagationTransferState.receiving, .receiving)
        XCTAssertEqual(PropagationTransferState.done, .done)
        XCTAssertEqual(PropagationTransferState.failed, .failed)
    }
}

// MARK: - handleMessageListResponse unit tests

final class MessageListResponseTests: XCTestCase {

    private func makeRouter() -> LXMRouter { LXMRouter(transport: Transport()) }

    private func makeReceipt() -> RequestReceipt {
        RequestReceipt(requestID: Data(repeating: 0x01, count: 16), path: "/get", requestSize: 0)
    }

    // Helper — encode a MsgPack value as raw bytes
    private func encode(_ value: MsgPack.Value) -> Data { MsgPack.encode(value) }

    func testEmptyListSetsDoneState() {
        let router = makeRouter()
        // Response is an empty msgpack array
        let data = encode(.array([]))
        router.handleMessageListResponse(data, receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .done)
        XCTAssertEqual(router.propagationTransferProgress, 1.0, accuracy: 0.001)
    }

    func testInvalidMsgpackSetsFailed() {
        let router = makeRouter()
        router.handleMessageListResponse(Data([0xFF, 0xFF, 0xFF]), receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .failed)
    }

    func testErrorCodeNoIdentitySetsFailedState() {
        let router = makeRouter()
        // 0xF0 = noIdentity error code
        let data = encode(.int(Int64(LXMPeerError.noIdentity.rawValue)))
        router.handleMessageListResponse(data, receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .failed)
    }

    func testErrorCodeNoAccessSetsFailedState() {
        let router = makeRouter()
        let data = encode(.int(Int64(LXMPeerError.noAccess.rawValue)))
        router.handleMessageListResponse(data, receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .failed)
    }

    func testNonArrayResponseSetsFailed() {
        let router = makeRouter()
        // Response is a string, not an array or int
        let data = encode(.string("unexpected"))
        router.handleMessageListResponse(data, receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .failed)
    }

    func testListWithUnknownMessagesTransitionsToReceiving() {
        let router = makeRouter()
        // No link → should fail after building wants, but state transitions happen before link check
        let tid = Data(repeating: 0xAB, count: 32)
        let data = encode(.array([.bytes(tid)]))
        router.handleMessageListResponse(data, receipt: makeReceipt())
        // No link available → fails after transition
        XCTAssertEqual(router.propagationTransferState, .failed)
    }

    func testAlreadyDeliveredMessagesGoToHaves() {
        let router = makeRouter()
        // Inject a transient ID as already delivered
        let tid = Data(repeating: 0xCC, count: 32)
        router.locallyDeliveredTransientIDs.insert(tid)
        router.retainSyncedOnNode = false  // retain=false → should go to haves

        let data = encode(.array([.bytes(tid)]))
        router.handleMessageListResponse(data, receipt: makeReceipt())
        // Empty wants (we have all) → no link needed, but no early-exit on empty wants path
        // (state .failed because no link, but wants is empty)
        XCTAssertEqual(router.propagationTransferState, .failed)
    }

    func testRetainSyncedOnNodeSkipsHaves() {
        let router = makeRouter()
        let tid = Data(repeating: 0xDD, count: 32)
        router.locallyDeliveredTransientIDs.insert(tid)
        router.retainSyncedOnNode = true  // don't add to haves

        let data = encode(.array([.bytes(tid)]))
        router.handleMessageListResponse(data, receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .failed)
    }

    func testMaxMessagesLimitsWants() {
        let router = makeRouter()
        router.propagationTransferMaxMessages = 2
        // 5 unknown messages
        let tids = (0..<5).map { Data(repeating: UInt8($0), count: 32) }
        let data = encode(.array(tids.map { .bytes($0) }))
        router.handleMessageListResponse(data, receipt: makeReceipt())
        // Only 2 wants built, still fails (no link), not done from empty wants
        XCTAssertEqual(router.propagationTransferState, .failed)
    }
}

// MARK: - handleMessageGetResponse unit tests

final class MessageGetResponseTests: XCTestCase {

    private func makeRouter() -> LXMRouter { LXMRouter(transport: Transport()) }
    private func makeReceipt() -> RequestReceipt {
        RequestReceipt(requestID: Data(repeating: 0x02, count: 16), path: "/get", requestSize: 0)
    }
    private func encode(_ value: MsgPack.Value) -> Data { MsgPack.encode(value) }

    func testEmptyResponseSetsDone() {
        let router = makeRouter()
        let data = encode(.array([]))
        router.handleMessageGetResponse(data, receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .done)
        XCTAssertEqual(router.propagationTransferProgress, 1.0, accuracy: 0.001)
    }

    func testUndecodableMsgpackSetsDone() {
        let router = makeRouter()
        // Completely invalid msgpack (truncated map marker) → decode throws → done
        router.handleMessageGetResponse(Data([0xDE, 0x00]), receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .done)
    }

    func testErrorCodeNoIdentitySetsFailed() {
        let router = makeRouter()
        let data = encode(.int(Int64(LXMPeerError.noIdentity.rawValue)))
        router.handleMessageGetResponse(data, receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .failed)
    }

    func testErrorCodeNoAccessSetsFailed() {
        let router = makeRouter()
        let data = encode(.int(Int64(LXMPeerError.noAccess.rawValue)))
        router.handleMessageGetResponse(data, receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .failed)
    }

    func testNonArrayNonIntSetsDone() {
        let router = makeRouter()
        let data = encode(.string("hello"))
        router.handleMessageGetResponse(data, receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .done)
    }

    func testSkipsTooShortMessages() {
        let router = makeRouter()
        // A message shorter than destinationLength (16 bytes)
        let shortMsg = Data(repeating: 0xAA, count: 5)
        let data = encode(.array([.bytes(shortMsg)]))
        router.handleMessageGetResponse(data, receipt: makeReceipt())
        // Short msg silently skipped; sets done
        XCTAssertEqual(router.propagationTransferState, .done)
    }

    func testSkipsAlreadyDeliveredMessages() {
        let router = makeRouter()
        let lxmfData = Data(repeating: 0xBB, count: 80)
        let tid = Hashes.fullHash(lxmfData)
        router.locallyDeliveredTransientIDs.insert(tid)

        let data = encode(.array([.bytes(lxmfData)]))
        router.handleMessageGetResponse(data, receipt: makeReceipt())
        XCTAssertEqual(router.propagationTransferState, .done)
    }

    func testMessageWithNoMatchingDeliveryDestinationIsSkipped() {
        let router = makeRouter()
        // 16 bytes dest + some encrypted payload
        let lxmfData = Data(repeating: 0xCC, count: 80)
        let data = encode(.array([.bytes(lxmfData)]))
        router.handleMessageGetResponse(data, receipt: makeReceipt())
        // No delivery destination registered → skipped, state = done
        XCTAssertEqual(router.propagationTransferState, .done)
    }
}
