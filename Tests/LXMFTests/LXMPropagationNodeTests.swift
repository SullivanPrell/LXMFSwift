import XCTest
@testable import LXMF
import ReticulumSwift

/// Tests for LXMRouter propagation node server:
///   enablePropagation, message store, peer management, offer/get handlers,
///   distribution queue, cleanMessageStore.
final class LXMPropagationNodeTests: XCTestCase {

    // Temp directory, cleaned after each test.
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    private func makeRouter() -> LXMRouter { LXMRouter(transport: Transport()) }

    private func fakeHash(_ byte: UInt8 = 0xAA) -> Data {
        // Destination hashes are 16 bytes (128-bit truncated hash)
        Data(repeating: byte, count: LXMessage.destinationLength)
    }

    // MARK: - Default state

    func testIsPropagationNodeFalseByDefault() {
        XCTAssertFalse(makeRouter().isPropagationNode)
    }

    func testPropagationNodeStartTimeNilByDefault() {
        XCTAssertNil(makeRouter().propagationNodeStartTime)
    }

    func testPropagationEntriesEmptyByDefault() {
        XCTAssertTrue(makeRouter().propagationEntries.isEmpty)
    }

    func testPeersEmptyByDefault() {
        XCTAssertTrue(makeRouter().peers.isEmpty)
    }

    // MARK: - enablePropagation

    func testEnablePropagationSetsFlag() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)
        XCTAssertTrue(router.isPropagationNode)
    }

    func testEnablePropagationSetsStartTime() throws {
        let before = Date().timeIntervalSince1970
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)
        XCTAssertNotNil(router.propagationNodeStartTime)
        XCTAssertGreaterThanOrEqual(router.propagationNodeStartTime!, before)
    }

    func testEnablePropagationCreatesDirectories() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: tempDir + "/lxmf"),
                      "lxmf/ directory must be created")
        XCTAssertTrue(fm.fileExists(atPath: tempDir + "/lxmf/messagestore"),
                      "lxmf/messagestore/ directory must be created")
    }

    func testEnablePropagationSetsStoragePath() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)
        XCTAssertEqual(router.storagePath, tempDir + "/lxmf")
        XCTAssertEqual(router.messagePath, tempDir + "/lxmf/messagestore")
    }

    func testEnablePropagationIndexesExistingMessages() throws {
        // Pre-create a fake message file in the store.
        let msgPath = tempDir + "/lxmf/messagestore"
        try FileManager.default.createDirectory(atPath: msgPath, withIntermediateDirectories: true)

        let destHash  = Data(repeating: 0x01, count: LXMessage.destinationLength)
        let lxmfBytes = destHash + Data(repeating: 0xFF, count: 50)
        let stamp     = Data(repeating: 0xAB, count: LXStamper.stampSize)
        var fileBytes = lxmfBytes
        fileBytes.append(stamp)

        let transientID = Hashes.fullHash(lxmfBytes)
        let hexID       = transientID.map { String(format: "%02x", $0) }.joined()
        let filename    = "\(hexID)_1000000.0_5"
        let filePath    = msgPath + "/" + filename
        try fileBytes.write(to: URL(fileURLWithPath: filePath))

        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        XCTAssertNotNil(router.propagationEntries[transientID],
                        "Existing message must be indexed after enablePropagation")
        XCTAssertEqual(router.propagationEntries[transientID]?.destinationHash, destHash)
        XCTAssertEqual(router.propagationEntries[transientID]?.stampValue, 5)
    }

    // MARK: - disablePropagation

    func testDisablePropagationClearsFlag() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)
        router.disablePropagation()
        XCTAssertFalse(router.isPropagationNode)
        XCTAssertNil(router.propagationNodeStartTime)
    }

    // MARK: - messageStorageSize

    func testMessageStorageSizeNilWhenNotEnabled() {
        XCTAssertNil(makeRouter().messageStorageSize())
    }

    func testMessageStorageSizeZeroWhenEmpty() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)
        XCTAssertEqual(router.messageStorageSize(), 0)
    }

    func testMessageStorageSizeSumsEntries() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        // Inject fake entries directly
        let tid1 = fakeHash(0x01)
        let tid2 = fakeHash(0x02)
        router.propagationEntries[tid1] = PropagationEntry(
            destinationHash: fakeHash(0xA0), filePath: "/tmp/a",
            received: 0, msgSize: 100, stampValue: 0)
        router.propagationEntries[tid2] = PropagationEntry(
            destinationHash: fakeHash(0xA1), filePath: "/tmp/b",
            received: 0, msgSize: 200, stampValue: 0)

        XCTAssertEqual(router.messageStorageSize(), 300)
    }

    // MARK: - setMessageStorageLimit

    func testSetMessageStorageLimitKilobytes() {
        let router = makeRouter()
        router.setMessageStorageLimit(kilobytes: 100)
        XCTAssertEqual(router.messageStorageLimit, 100_000)
    }

    func testSetMessageStorageLimitMegabytes() {
        let router = makeRouter()
        router.setMessageStorageLimit(megabytes: 10)
        XCTAssertEqual(router.messageStorageLimit, 10_000_000)
    }

    func testSetMessageStorageLimitCombined() {
        let router = makeRouter()
        router.setMessageStorageLimit(kilobytes: 500, megabytes: 1)
        XCTAssertEqual(router.messageStorageLimit, 1_500_000)
    }

    func testSetMessageStorageLimitNilWhenZero() {
        let router = makeRouter()
        router.setMessageStorageLimit()  // no args → nil
        XCTAssertNil(router.messageStorageLimit)
    }

    // MARK: - addToMessageStore

    func testAddToMessageStoreCreatesFile() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let destHash  = Data(repeating: 0x11, count: LXMessage.destinationLength)
        let lxmfBytes = destHash + Data(repeating: 0x22, count: 50)
        let stamp     = Data(repeating: 0x33, count: LXStamper.stampSize)
        let tid       = Hashes.fullHash(lxmfBytes)

        let entry = router.addToMessageStore(lxmfData: lxmfBytes, transientID: tid,
                                              stampValue: 7, stamp: stamp)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.destinationHash, destHash)
        XCTAssertEqual(entry?.stampValue, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry!.filePath),
                      "Message file must exist on disk")
    }

    func testAddToMessageStoreIndexesEntry() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let destHash  = Data(repeating: 0x11, count: LXMessage.destinationLength)
        let lxmfBytes = destHash + Data(repeating: 0x22, count: 50)
        let stamp     = Data(repeating: 0x33, count: LXStamper.stampSize)
        let tid       = Hashes.fullHash(lxmfBytes)

        router.addToMessageStore(lxmfData: lxmfBytes, transientID: tid,
                                  stampValue: 7, stamp: stamp)
        XCTAssertNotNil(router.propagationEntries[tid])
    }

    func testAddToMessageStoreSkipsDuplicates() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let destHash  = Data(repeating: 0x11, count: LXMessage.destinationLength)
        let lxmfBytes = destHash + Data(repeating: 0x22, count: 50)
        let stamp     = Data(repeating: 0x33, count: LXStamper.stampSize)
        let tid       = Hashes.fullHash(lxmfBytes)

        router.addToMessageStore(lxmfData: lxmfBytes, transientID: tid, stampValue: 7, stamp: stamp)
        router.addToMessageStore(lxmfData: lxmfBytes, transientID: tid, stampValue: 7, stamp: stamp)
        XCTAssertEqual(router.propagationEntries.count, 1, "Duplicate must not create second entry")
    }

    // MARK: - removeFromMessageStore

    func testRemoveFromMessageStore() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let destHash  = Data(repeating: 0x11, count: LXMessage.destinationLength)
        let lxmfBytes = destHash + Data(repeating: 0x22, count: 50)
        let stamp     = Data(repeating: 0x33, count: LXStamper.stampSize)
        let tid       = Hashes.fullHash(lxmfBytes)
        router.addToMessageStore(lxmfData: lxmfBytes, transientID: tid, stampValue: 7, stamp: stamp)

        let filePath = router.propagationEntries[tid]!.filePath
        router.removeFromMessageStore(transientID: tid)

        XCTAssertNil(router.propagationEntries[tid], "Entry must be removed from index")
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath),
                       "File must be deleted from disk")
    }

    // MARK: - cleanMessageStore

    func testCleanMessageStoreNoopsWhenUnderLimit() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)
        router.setMessageStorageLimit(megabytes: 100)

        // Inject two 100-byte entries
        for byte: UInt8 in [0x01, 0x02] {
            let tid = fakeHash(byte)
            router.propagationEntries[tid] = PropagationEntry(
                destinationHash: fakeHash(byte ^ 0xF0), filePath: "/tmp/\(byte)",
                received: Double(byte), msgSize: 100, stampValue: 0)
        }
        router.cleanMessageStore()
        XCTAssertEqual(router.propagationEntries.count, 2, "Nothing should be removed under the limit")
    }

    func testCleanMessageStoreRemovesOldestWhenOverLimit() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)
        router.setMessageStorageLimit(kilobytes: 1)  // 1000 bytes

        // Old message (received=1)
        let oldTID = fakeHash(0x01)
        router.propagationEntries[oldTID] = PropagationEntry(
            destinationHash: fakeHash(0xA1), filePath: tempDir + "/old",
            received: 1.0, msgSize: 600, stampValue: 0)

        // Newer message (received=2)
        let newTID = fakeHash(0x02)
        router.propagationEntries[newTID] = PropagationEntry(
            destinationHash: fakeHash(0xA2), filePath: tempDir + "/new",
            received: 2.0, msgSize: 600, stampValue: 0)

        // Total = 1200 bytes > 1000 limit → old message should be dropped
        router.cleanMessageStore()

        XCTAssertNil(router.propagationEntries[oldTID], "Oldest message must be removed")
        XCTAssertNotNil(router.propagationEntries[newTID], "Newer message must remain")
    }

    // MARK: - addPeer / removePeer

    func testAddPeerCreatesEntry() {
        let router = makeRouter()
        let hash   = fakeHash(0xBB)
        let peer   = router.addPeer(destinationHash: hash)
        XCTAssertNotNil(router.peers[hash])
        XCTAssertEqual(peer.destinationHash, hash)
    }

    func testAddPeerIsIdempotent() {
        let router = makeRouter()
        let hash   = fakeHash(0xBB)
        let peer1  = router.addPeer(destinationHash: hash)
        let peer2  = router.addPeer(destinationHash: hash)
        XCTAssertTrue(peer1 === peer2, "Second addPeer must return the same object")
        XCTAssertEqual(router.peers.count, 1)
    }

    func testAddPeerMarksExistingMessagesAsUnhandled() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        // Pre-populate a message entry
        let tid = fakeHash(0x01)
        router.propagationEntries[tid] = PropagationEntry(
            destinationHash: fakeHash(0xA0), filePath: "/tmp/x",
            received: 0, msgSize: 100, stampValue: 0)

        let hash = fakeHash(0xBB)
        let peer = router.addPeer(destinationHash: hash)
        XCTAssertTrue(peer.unhandledMessages.contains(tid),
                      "Existing messages must be queued as unhandled for new peer")
    }

    func testRemovePeer() {
        let router = makeRouter()
        let hash   = fakeHash(0xCC)
        router.addPeer(destinationHash: hash)
        router.removePeer(destinationHash: hash)
        XCTAssertNil(router.peers[hash])
    }

    // MARK: - peerDistributionQueue

    func testEnqueueForPeerDistribution() {
        let router = makeRouter()
        let tid    = fakeHash(0x01)
        router.enqueueForPeerDistribution(transientID: tid)
        XCTAssertTrue(router.peerDistributionQueue.contains(tid))
    }

    func testEnqueueDeduplicates() {
        let router = makeRouter()
        let tid    = fakeHash(0x01)
        router.enqueueForPeerDistribution(transientID: tid)
        router.enqueueForPeerDistribution(transientID: tid)
        XCTAssertEqual(router.peerDistributionQueue.count, 1)
    }

    func testFlushPeerDistributionQueueMarksPeerUnhandled() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let tid  = fakeHash(0x01)
        let hash = fakeHash(0xBB)
        router.propagationEntries[tid] = PropagationEntry(
            destinationHash: fakeHash(0xA0), filePath: "/tmp/x",
            received: 0, msgSize: 100, stampValue: 0)

        let peer = router.addPeer(destinationHash: hash)
        // Reset unhandled (was set by addPeer) to simulate a fresh message
        peer.removeUnhandledMessage(tid)

        router.enqueueForPeerDistribution(transientID: tid)
        router.flushPeerDistributionQueue()

        XCTAssertTrue(peer.unhandledMessages.contains(tid),
                      "Flushed message must be marked unhandled for peer")
        XCTAssertTrue(router.peerDistributionQueue.isEmpty,
                      "Queue must be empty after flush")
    }

    // MARK: - handleOfferRequest

    func testHandleOfferRequestNoIdentity() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let result = router.handleOfferRequest(
            data: .array([.bytes(Data()), .array([])]),
            remoteIdentityHash: nil,
            linkID: ObjectIdentifier(router)
        )
        if case .int(let code) = result {
            XCTAssertEqual(code, Int64(LXMPeerError.noIdentity.rawValue))
        } else { XCTFail("Expected noIdentity error") }
    }

    func testHandleOfferRequestNotEnabledReturnsNoAccess() {
        let router = makeRouter()  // not enabled
        let result = router.handleOfferRequest(
            data: .array([.bytes(Data()), .array([])]),
            remoteIdentityHash: fakeHash(),
            linkID: ObjectIdentifier(router)
        )
        if case .int(let code) = result {
            XCTAssertEqual(code, Int64(LXMPeerError.noAccess.rawValue))
        } else { XCTFail("Expected noAccess error") }
    }

    func testHandleOfferRequestWantsAllNewMessages() throws {
        let router = makeRouter()
        router.peeringCost = 0  // no PoW required
        try router.enablePropagation(storagePath: tempDir)

        let tid1 = fakeHash(0x01)
        let tid2 = fakeHash(0x02)
        // Neither tid is in propagationEntries → we want both

        let data = MsgPack.Value.array([
            .bytes(Data(repeating: 0x00, count: 32)),  // peering key (no cost)
            .array([.bytes(tid1), .bytes(tid2)])
        ])
        let result = router.handleOfferRequest(
            data: data,
            remoteIdentityHash: fakeHash(0xCC),
            linkID: ObjectIdentifier(router)
        )
        if case .bool(let b) = result { XCTAssertTrue(b) }
        else { XCTFail("Expected .bool(true) when all IDs are new") }
    }

    func testHandleOfferRequestWantsNoneWhenAlreadyHave() throws {
        let router = makeRouter()
        router.peeringCost = 0
        try router.enablePropagation(storagePath: tempDir)

        let tid = fakeHash(0x01)
        router.propagationEntries[tid] = PropagationEntry(
            destinationHash: fakeHash(0xA0), filePath: "/tmp/x",
            received: 0, msgSize: 100, stampValue: 0)

        let data = MsgPack.Value.array([
            .bytes(Data(repeating: 0x00, count: 32)),
            .array([.bytes(tid)])
        ])
        let result = router.handleOfferRequest(
            data: data,
            remoteIdentityHash: fakeHash(0xCC),
            linkID: ObjectIdentifier(router)
        )
        if case .bool(let b) = result { XCTAssertFalse(b) }
        else { XCTFail("Expected .bool(false) when all IDs are already stored") }
    }

    func testHandleOfferRequestPartialWanted() throws {
        let router = makeRouter()
        router.peeringCost = 0
        try router.enablePropagation(storagePath: tempDir)

        let existingTID = fakeHash(0x01)
        let newTID      = fakeHash(0x02)
        router.propagationEntries[existingTID] = PropagationEntry(
            destinationHash: fakeHash(0xA0), filePath: "/tmp/x",
            received: 0, msgSize: 100, stampValue: 0)
        // newTID is not stored → we want it

        let data = MsgPack.Value.array([
            .bytes(Data(repeating: 0x00, count: 32)),
            .array([.bytes(existingTID), .bytes(newTID)])
        ])
        let result = router.handleOfferRequest(
            data: data,
            remoteIdentityHash: fakeHash(0xCC),
            linkID: ObjectIdentifier(router)
        )
        if case .array(let wanted) = result {
            XCTAssertEqual(wanted.count, 1)
            if case .bytes(let b) = wanted[0] { XCTAssertEqual(Data(b), newTID) }
        } else { XCTFail("Expected partial wanted array") }
    }

    // MARK: - handleMessageGetRequest

    func testHandleMessageGetRequestNoIdentityReturnsError() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)
        let result = router.handleMessageGetRequest(
            data: .array([.nil, .nil]),
            remoteDeliveryHash: nil)
        if case .int(let code) = result {
            XCTAssertEqual(code, Int64(LXMPeerError.noIdentity.rawValue))
        } else { XCTFail("Expected noIdentity") }
    }

    func testHandleMessageGetRequestListAvailableMessages() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let destHash = fakeHash(0x44)
        let tid      = fakeHash(0x01)
        router.propagationEntries[tid] = PropagationEntry(
            destinationHash: destHash, filePath: "/tmp/x",
            received: 0, msgSize: 100, stampValue: 0)

        // want=nil, have=nil → return list
        let result = router.handleMessageGetRequest(
            data: .array([.nil, .nil]),
            remoteDeliveryHash: destHash)

        if case .array(let ids) = result {
            XCTAssertEqual(ids.count, 1)
            if case .bytes(let b) = ids[0] { XCTAssertEqual(Data(b), tid) }
        } else { XCTFail("Expected array of transient IDs") }
    }

    func testHandleMessageGetRequestListExcludesOtherDestinations() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let myDest    = fakeHash(0x44)
        let otherDest = fakeHash(0x55)
        let myTID     = fakeHash(0x01)
        let otherTID  = fakeHash(0x02)

        router.propagationEntries[myTID] = PropagationEntry(
            destinationHash: myDest, filePath: "/tmp/x",
            received: 0, msgSize: 100, stampValue: 0)
        router.propagationEntries[otherTID] = PropagationEntry(
            destinationHash: otherDest, filePath: "/tmp/y",
            received: 0, msgSize: 100, stampValue: 0)

        let result = router.handleMessageGetRequest(
            data: .array([.nil, .nil]),
            remoteDeliveryHash: myDest)

        if case .array(let ids) = result {
            XCTAssertEqual(ids.count, 1)
        } else { XCTFail() }
    }

    func testHandleMessageGetRequestHaveListDeletesMessages() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        // Write a real file so delete succeeds
        let destHash  = fakeHash(0x44)
        let lxmfBytes = destHash + Data(repeating: 0x22, count: 50)
        let stamp     = Data(repeating: 0x33, count: LXStamper.stampSize)
        let tid       = Hashes.fullHash(lxmfBytes)
        router.addToMessageStore(lxmfData: lxmfBytes, transientID: tid, stampValue: 7, stamp: stamp)

        let filePath = router.propagationEntries[tid]!.filePath

        // Client says it has this message (have=[tid])
        let result = router.handleMessageGetRequest(
            data: .array([.nil, .array([.bytes(tid)])]),
            remoteDeliveryHash: destHash)

        XCTAssertNil(router.propagationEntries[tid], "Message must be deleted when client reports having it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath))
        _ = result
    }

    // MARK: - ingestPropagatedLXM

    func testIngestPropagatedLXMStoresMessage() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let destHash  = fakeHash(0x55)
        let lxmfBytes = destHash + Data(repeating: 0x66, count: 50)
        let stamp     = Data(repeating: 0x77, count: LXStamper.stampSize)

        let entry = router.ingestPropagatedLXM(lxmfData: lxmfBytes, stampValue: 4, stamp: stamp)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.destinationHash, destHash)
        XCTAssertEqual(router.propagationEntries.count, 1)
    }

    func testIngestPropagatedLXMSkipsDuplicates() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let destHash  = fakeHash(0x55)
        let lxmfBytes = destHash + Data(repeating: 0x66, count: 50)
        let stamp     = Data(repeating: 0x77, count: LXStamper.stampSize)

        router.ingestPropagatedLXM(lxmfData: lxmfBytes, stampValue: 4, stamp: stamp)
        router.ingestPropagatedLXM(lxmfData: lxmfBytes, stampValue: 4, stamp: stamp)
        XCTAssertEqual(router.propagationEntries.count, 1)
    }

    func testIngestPropagatedLXMEnqueuesForDistribution() throws {
        let router = makeRouter()
        try router.enablePropagation(storagePath: tempDir)

        let destHash  = fakeHash(0x55)
        let lxmfBytes = destHash + Data(repeating: 0x66, count: 50)
        let stamp     = Data(repeating: 0x77, count: LXStamper.stampSize)

        router.ingestPropagatedLXM(lxmfData: lxmfBytes, stampValue: 4, stamp: stamp)
        XCTAssertFalse(router.peerDistributionQueue.isEmpty,
                       "Ingested message must be queued for peer distribution")
    }

    // MARK: - syncPeers

    func testSyncPeersNoopsWhenNotEnabled() {
        let router = makeRouter()
        router.syncPeers()  // must not crash
    }

    // MARK: - Persistence round-trip

    func testSavePeersAndReloadOnEnable() throws {
        let router1 = makeRouter()
        try router1.enablePropagation(storagePath: tempDir)
        let peerHash = fakeHash(0xEE)
        let peer     = router1.addPeer(destinationHash: peerHash)
        peer.offered  = 5
        peer.lastHeard = 1_234_567.0
        router1.savePeers()

        // New router, same storage path
        let router2 = makeRouter()
        try router2.enablePropagation(storagePath: tempDir)
        let loaded = try XCTUnwrap(router2.peers[peerHash], "Peer must be reloaded from disk")
        XCTAssertEqual(loaded.offered,   5)
        XCTAssertEqual(loaded.lastHeard, 1_234_567.0, accuracy: 0.001)
    }

    func testSaveNodeStatsAndReloadOnEnable() throws {
        let router1 = makeRouter()
        try router1.enablePropagation(storagePath: tempDir)
        router1.clientPropagationMessagesReceived = 42
        router1.clientPropagationMessagesServed   = 17
        router1.saveNodeStats()

        let router2 = makeRouter()
        try router2.enablePropagation(storagePath: tempDir)
        XCTAssertEqual(router2.clientPropagationMessagesReceived, 42)
        XCTAssertEqual(router2.clientPropagationMessagesServed,   17)
    }

    // MARK: - getStampValue / getWeight / getSize

    func testGetStampValue() {
        let router = makeRouter()
        let tid    = fakeHash(0x01)
        router.propagationEntries[tid] = PropagationEntry(
            destinationHash: fakeHash(0xA0), filePath: "/tmp/x",
            received: 9999.0, msgSize: 200, stampValue: 13)
        XCTAssertEqual(router.getStampValue(transientID: tid), 13)
    }

    func testGetWeight() {
        let router = makeRouter()
        let tid    = fakeHash(0x01)
        router.propagationEntries[tid] = PropagationEntry(
            destinationHash: fakeHash(0xA0), filePath: "/tmp/x",
            received: 9999.0, msgSize: 200, stampValue: 0)
        XCTAssertEqual(router.getWeight(transientID: tid), 9999.0, accuracy: 0.001)
    }

    func testGetSize() {
        let router = makeRouter()
        let tid    = fakeHash(0x01)
        router.propagationEntries[tid] = PropagationEntry(
            destinationHash: fakeHash(0xA0), filePath: "/tmp/x",
            received: 0, msgSize: 512, stampValue: 0)
        XCTAssertEqual(router.getSize(transientID: tid), 512)
    }

    // MARK: - LXMRouter.identity property

    func testIdentityNilByDefault() {
        XCTAssertNil(makeRouter().identity)
    }

    func testIdentitySetAfterRegister() throws {
        let router   = makeRouter()
        let identity = Identity()
        let transport = Transport()
        try router.register(identity: identity, transport: transport)
        XCTAssertNotNil(router.identity)
        XCTAssertEqual(router.identity?.hash, identity.hash)
    }

    // MARK: - Propagation node app data + announce API

    func testGetPropagationNodeAppDataIsValidMsgpack() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())
        try router.enablePropagation(storagePath: tempDir)
        let appData = router.getPropagationNodeAppData()
        guard case .array(let fields) = try? MsgPack.decode(appData),
              fields.count == 7 else {
            XCTFail("app data must be a 7-element array"); return
        }
        // Field 0: False (legacy support)
        XCTAssertEqual(fields[0], .bool(false))
        // Field 2: true (node is active)
        XCTAssertEqual(fields[2], .bool(true))
        // Field 5: [stampCost, flexibility, peeringCost]
        if case .array(let costs) = fields[5] {
            XCTAssertEqual(costs.count, 3)
        } else { XCTFail("field 5 must be array") }
    }

    func testGetPropagationNodeAppDataNotActiveWhenDisabled() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())
        let appData = router.getPropagationNodeAppData()
        guard case .array(let fields) = try? MsgPack.decode(appData) else { XCTFail(); return }
        XCTAssertEqual(fields[2], .bool(false), "node not active before enablePropagation")
    }

    func testAnnouncePropagationNodeReturnNilIfNoDestination() throws {
        let router = makeRouter()  // No register() call — no propagation destination
        let receipt = try router.announcePropagationNode()
        XCTAssertNil(receipt)
    }

    func testAnnouncePropagationNodeDoesNotThrow() throws {
        let router = makeRouter()
        let id = Identity()
        let transport = Transport()
        try router.register(identity: id, transport: transport)
        try router.enablePropagation(storagePath: tempDir)
        // Reticulum.shared is nil in unit tests so receipt is nil, but must not throw.
        XCTAssertNoThrow(try router.announcePropagationNode())
    }

    // MARK: - Propagation destination creation

    func testPropagationDestinationNilBeforeRegister() {
        let router = makeRouter()
        XCTAssertNil(router.propagationDestination)
    }

    func testRegisterCreatesPropagationDestination() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())
        XCTAssertNotNil(router.propagationDestination)
    }

    func testPropagationDestinationHashMatchesIdentity() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())
        let expected = try Destination(identity: id, direction: .in, kind: .single,
                                       appName: "lxmf", aspects: ["propagation"]).hash
        XCTAssertEqual(router.propagationDestination?.hash, expected)
    }

    func testSecondRegisterDoesNotChangePropagationDestination() throws {
        let router = makeRouter()
        let id1 = Identity(); let id2 = Identity()
        try router.register(identity: id1, transport: Transport())
        let hashBefore = router.propagationDestination?.hash
        try router.register(identity: id2, transport: Transport())
        XCTAssertEqual(router.propagationDestination?.hash, hashBefore,
                       "Propagation destination must not change after the first register call")
    }

    // MARK: - Server-side request handler registration

    func testEnablePropagationRegistersMessageGetHandler() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())
        try router.enablePropagation(storagePath: tempDir)

        let pathHash = Hashes.truncatedHash(Data(LXMPeer.messageGetPath.utf8))
        XCTAssertNotNil(router.propagationDestination?.requestHandlers[pathHash],
                        "message_get handler must be registered after enablePropagation")
    }

    func testEnablePropagationRegistersOfferRequestHandler() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())
        try router.enablePropagation(storagePath: tempDir)

        let pathHash = Hashes.truncatedHash(Data(LXMPeer.offerRequestPath.utf8))
        XCTAssertNotNil(router.propagationDestination?.requestHandlers[pathHash],
                        "offer request handler must be registered after enablePropagation")
    }

    func testDisablePropagationDeregistersMessageGetHandler() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())
        try router.enablePropagation(storagePath: tempDir)
        router.disablePropagation()

        let pathHash = Hashes.truncatedHash(Data(LXMPeer.messageGetPath.utf8))
        XCTAssertNil(router.propagationDestination?.requestHandlers[pathHash],
                     "message_get handler must be deregistered after disablePropagation")
    }

    func testDisablePropagationDeregistersOfferHandler() throws {
        let router = makeRouter()
        let id = Identity()
        try router.register(identity: id, transport: Transport())
        try router.enablePropagation(storagePath: tempDir)
        router.disablePropagation()

        let pathHash = Hashes.truncatedHash(Data(LXMPeer.offerRequestPath.utf8))
        XCTAssertNil(router.propagationDestination?.requestHandlers[pathHash],
                     "offer request handler must be deregistered after disablePropagation")
    }

    /// End-to-end test: a Swift propagation node returns a native msgpack list
    /// of transient IDs when a client connects and sends the initial list request.
    func testPropagationNodeServesMessageListNatively() throws {
        // Set up a loopback transport pair.
        let serverTransport = Transport()
        let clientTransport = Transport()

        let serverId = Identity()
        let clientId = Identity()

        let router = LXMRouter(transport: serverTransport)
        try router.register(identity: serverId, transport: serverTransport)
        try router.enablePropagation(storagePath: tempDir)

        // Inject a fake propagation entry destined for the client.
        let clientDeliveryDest = try Destination(
            identity: clientId, direction: .in, kind: .single,
            appName: "lxmf", aspects: ["delivery"]
        )
        let fakeTransientID = Hashes.fullHash(Data("fake_msg".utf8))
        router.propagationEntries[fakeTransientID] = PropagationEntry(
            destinationHash: clientDeliveryDest.hash, filePath: "/tmp/fake",
            received: 0, msgSize: 64, stampValue: 0
        )

        // Wire up loopback interfaces.
        let serverIface = LoopIface(name: "S"); let clientIface = LoopIface(name: "C")
        serverIface.paired = clientIface; clientIface.paired = serverIface
        serverTransport.register(interface: serverIface)
        clientTransport.register(interface: clientIface)

        guard let propDest = router.propagationDestination else {
            XCTFail("propagationDestination not created"); return
        }
        serverTransport.register(destination: propDest)

        // Client opens link to the propagation destination.
        let linkEstA = expectation(description: "client link established")
        let linkEstB = expectation(description: "server link established")
        clientTransport.onLinkEstablished = { _ in linkEstA.fulfill() }
        serverTransport.onLinkEstablished = { _ in linkEstB.fulfill() }
        let clientLink = try Link.initiate(destination: propDest, transport: clientTransport)
        wait(for: [linkEstA, linkEstB], timeout: 2.0)

        // Client identifies themselves so the server knows who they are.
        let serverLink = try XCTUnwrap(serverTransport.links[clientLink.linkID!])
        let identifiedExp = expectation(description: "server sees client identity")
        serverLink.onRemoteIdentified = { _, _ in identifiedExp.fulfill() }
        try clientLink.identify(as: clientId)
        wait(for: [identifiedExp], timeout: 1.0)

        // Client sends the initial message-list request: [nil, nil]
        let responseExp = expectation(description: "list response received")
        var responseData: Data?
        let receipt = try clientLink.request(
            path: LXMPeer.messageGetPath,
            nativeValue: MsgPack.Value.array([.nil, .nil]),
            responseCallback: { data, _ in responseData = data; responseExp.fulfill() }
        )

        wait(for: [responseExp], timeout: 2.0)

        // Response must be a native array of transient IDs (not bytes-wrapped).
        let decoded = try XCTUnwrap(responseData.flatMap { try? MsgPack.decode($0) })
        guard case .array(let ids) = decoded else {
            XCTFail("Response must be an array of transient IDs, got \(decoded)"); return
        }
        XCTAssertEqual(ids.count, 1, "Should return one message for the client")
        if case .bytes(let tid) = ids[0] {
            XCTAssertEqual(Data(tid), fakeTransientID,
                           "Returned transient ID must match the stored entry")
        } else {
            XCTFail("Each element must be .bytes, got \(ids[0])")
        }
        _ = (receipt, clientLink)
    }

    /// End-to-end test: a client uploads a resource to the Swift propagation node
    /// and the PN ingests the message into its store.
    func testPropagationNodeAcceptsInboundResourceUpload() throws {
        let serverTransport = Transport()
        let clientTransport = Transport()
        let serverId = Identity()
        let clientId = Identity()

        let router = LXMRouter(transport: serverTransport)
        try router.register(identity: serverId, transport: serverTransport)
        try router.enablePropagation(storagePath: tempDir)

        let serverIface = LoopIface(name: "S2"); let clientIface = LoopIface(name: "C2")
        serverIface.paired = clientIface; clientIface.paired = serverIface
        serverTransport.register(interface: serverIface)
        clientTransport.register(interface: clientIface)

        let propDest = try XCTUnwrap(router.propagationDestination)
        serverTransport.register(destination: propDest)

        let linkEstA = expectation(description: "client link est")
        let linkEstB = expectation(description: "server link est")
        clientTransport.onLinkEstablished = { _ in linkEstA.fulfill() }
        serverTransport.onLinkEstablished = { _ in linkEstB.fulfill() }
        let clientLink = try Link.initiate(destination: propDest, transport: clientTransport)
        wait(for: [linkEstA, linkEstB], timeout: 2.0)

        // Build a fake propagation resource payload: [timestamp, [lxmfDataWithStamp]].
        // Use a real message so the stamp validates.
        let srcId = Identity()
        let dstId = clientId  // destination = the "client" in this test (reverse of what server expects)
        let srcDest = try Destination(identity: srcId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dstDest = try Destination(identity: dstId, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let msg = LXMessage(destination: dstDest, source: srcDest, content: "hello PN")
        try msg.pack()
        // Compute stamp for this message.
        let lxmfData = try XCTUnwrap(msg.packed)
        let stampCost = 0  // cost=0 means always valid
        let stamp = try XCTUnwrap(LXStamper.generateStamp(messageID: Hashes.fullHash(lxmfData), stampCost: stampCost))
        let lxmfWithStamp = lxmfData + stamp

        let ts = Date().timeIntervalSince1970
        let payload = MsgPack.encode(.array([.double(ts), .array([.bytes(lxmfWithStamp)])]))

        // Upload as a resource to the propagation destination.
        let uploadExp = expectation(description: "upload complete")
        let sender = ResourceTransfer(link: clientLink)
        sender.onComplete = { _ in uploadExp.fulfill() }
        try sender.send(payload: payload)
        wait(for: [uploadExp], timeout: 3.0)

        // Allow server to process.
        let transientID = Hashes.fullHash(lxmfData)
        XCTAssertNotNil(router.propagationEntries[transientID],
                        "PN should have ingested the uploaded message")
    }
}

// MARK: - Local interface helper for server-side tests

private final class LoopIface: Interface {
    let name: String
    var bitrate: Int = 1_000_000
    var isOnline: Bool = true
    var inboundHandler: ((Packet, any Interface) -> Void)?
    weak var paired: LoopIface?
    init(name: String) { self.name = name }
    func send(_ packet: Packet) throws {
        let raw = try packet.pack()
        let copy = try Packet.unpack(raw)
        paired?.inboundHandler?(copy, paired!)
    }
    func start() throws {}
    func stop() {}
}
