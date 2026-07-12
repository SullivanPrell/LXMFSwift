import XCTest
import ReticulumSwift
@testable import LXMF

/// Tests that LXMRouter client state (locally-delivered transient ids, outbound
/// stamp costs, available tickets) is persisted to disk and restored on the next
/// launch — parity with Python LXMRouter, which reads these files at startup.
final class ClientStatePersistenceTests: XCTestCase {

    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "lxmf-persist-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func makeRouter() -> LXMRouter { LXMRouter(transport: Transport()) }

    // MARK: - outbound stamp costs

    func testOutboundStampCostsPersistAcrossRestart() {
        let dest = Data(repeating: 0xA1, count: 16)

        let a = makeRouter()
        a.storagePath = dir
        a.setOutboundStampCost(destinationHash: dest, stampCost: 12)

        // Fresh router pointed at the same storage loads the persisted cost.
        let b = makeRouter()
        b.storagePath = dir
        XCTAssertEqual(b.getOutboundStampCost(destinationHash: dest), 12,
                       "outbound stamp cost must survive a restart")
    }

    func testOutboundStampCostFileIsWritten() {
        let a = makeRouter()
        a.storagePath = dir
        a.setOutboundStampCost(destinationHash: Data(repeating: 0x02, count: 16), stampCost: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/outbound_stamp_costs"),
                      "setting a stamp cost must write outbound_stamp_costs")
    }

    // MARK: - locally delivered transient ids

    func testLocallyDeliveredTransientIDsPersistAcrossRestart() {
        let tid = Data(repeating: 0xBB, count: 32)

        let a = makeRouter()
        a.storagePath = dir
        a.locallyDeliveredTransientIDs.insert(tid)   // single-threaded test; direct mutation
        a.saveLocallyDeliveredTransientIDs()

        let b = makeRouter()
        b.storagePath = dir
        XCTAssertTrue(b.hasMessage(transientID: tid),
                      "a delivered transient id must be remembered after a restart (dedup)")
    }

    // MARK: - available tickets

    func testOutboundTicketPersistsAcrossRestart() {
        let dest = Data(repeating: 0xC3, count: 16)
        let ticket = Data(repeating: 0x44, count: LXMessage.ticketLength)
        let expiry = Date().timeIntervalSince1970 + 100_000

        let a = makeRouter()
        a.storagePath = dir
        a.rememberTicket(destinationHash: dest, expiry: expiry, ticket: ticket)

        let b = makeRouter()
        b.storagePath = dir
        XCTAssertEqual(b.getOutboundTicket(destinationHash: dest), ticket,
                       "a remembered outbound ticket must survive a restart")
    }

    func testInboundTicketPersistsAcrossRestart() {
        let dest = Data(repeating: 0xD5, count: 16)

        let a = makeRouter()
        a.storagePath = dir
        guard let generated = a.generateTicket(destinationHash: dest) else {
            return XCTFail("generateTicket returned nil")
        }

        let b = makeRouter()
        b.storagePath = dir
        XCTAssertEqual(b.getInboundTickets(destinationHash: dest), [generated.ticket],
                       "a generated inbound ticket must survive a restart")
    }

    // MARK: - robustness

    func testMissingFilesLeaveStateEmpty() {
        // Pointing at an empty dir must not crash and must leave state clean.
        let r = makeRouter()
        r.storagePath = dir
        XCTAssertNil(r.getOutboundStampCost(destinationHash: Data(repeating: 0x01, count: 16)))
        XCTAssertFalse(r.hasMessage(transientID: Data(repeating: 0x02, count: 32)))
        XCTAssertNil(r.getOutboundTicket(destinationHash: Data(repeating: 0x03, count: 16)))
    }

    func testCorruptFileIsIgnored() {
        try? Data("not msgpack".utf8).write(to: URL(fileURLWithPath: dir + "/outbound_stamp_costs"))
        let r = makeRouter()
        r.storagePath = dir   // must not crash on corrupt file
        XCTAssertNil(r.getOutboundStampCost(destinationHash: Data(repeating: 0x09, count: 16)))
    }
}
