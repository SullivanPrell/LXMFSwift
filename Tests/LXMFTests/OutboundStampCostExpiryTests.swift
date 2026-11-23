//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXMFSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import ReticulumSwift
import XCTest

@testable import LXMF

/// Learned outbound stamp costs, as Python keeps them.
///
/// `update_stamp_cost` stores `[time, cost]` for every delivery announce, `None` included
/// (`LXMRouter.py:1156-1163`, `Handlers.py:17-18`). An entry older than `STAMP_COST_EXPIRY`
/// (45 days) is dropped (`:1469-1478`), and an unchanged cost is saved by the jobs loop every
/// `JOB_STAMPCOST_INTERVAL` ticks rather than on every announce (`:1012-1017`).
final class OutboundStampCostExpiryTests: XCTestCase {

  private var dir: String!
  private let dest = Data(repeating: 0xB1, count: 16)

  override func setUp() {
    super.setUp()
    dir = NSTemporaryDirectory() + "lxmf_stampcost_\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: dir)
    super.tearDown()
  }

  private var file: URL { URL(fileURLWithPath: dir + "/outbound_stamp_costs") }

  private func router() -> LXMRouter {
    let router = LXMRouter(transport: Transport())
    router.storagePath = dir
    return router
  }

  private func writeFile(_ pairs: [(Data, MsgPack.Value)]) throws {
    try MsgPack.encode(.map(pairs.map { (.bytes($0.0), $0.1) })).write(to: file)
  }

  func testAnAnnounceWithoutACostClearsTheLearnedOne() {
    let router = router()
    router.setOutboundStampCost(destinationHash: dest, stampCost: 8)
    router.setOutboundStampCost(destinationHash: dest, stampCost: nil)
    XCTAssertNil(router.getOutboundStampCost(destinationHash: dest))
  }

  func testTheFileIsPythonsTimeAndCostPairs() throws {
    let before = Date().timeIntervalSince1970
    router().setOutboundStampCost(destinationHash: dest, stampCost: 9)
    guard case .map(let pairs) = try MsgPack.decode(Data(contentsOf: file)),
      case .array(let entry) = pairs.first?.1, entry.count == 2
    else { return XCTFail("expected {hash: [time, cost]}") }
    XCTAssertEqual(pairs.first?.0, .bytes(dest))
    XCTAssertGreaterThanOrEqual(entry[0].asDouble ?? 0, before)
    XCTAssertEqual(entry[1].asDouble, 9)
  }

  func testAnEntryOlderThanFortyFiveDaysIsDroppedOnLoad() throws {
    let fresh = Data(repeating: 0xB2, count: 16)
    let now = Date().timeIntervalSince1970
    try writeFile([
      (dest, .array([.double(now - 46 * 24 * 3600), .int(8)])),
      (fresh, .array([.double(now - 44 * 24 * 3600), .int(7)])),
    ])
    let router = router()
    XCTAssertNil(router.getOutboundStampCost(destinationHash: dest))
    XCTAssertEqual(router.getOutboundStampCost(destinationHash: fresh), 7)
  }

  func testTheJobDropsAnEntryThatExpiredWhileRunning() throws {
    let router = router()
    router.seedOutboundStampCost(dest, cost: 8, at: Date().timeIntervalSince1970 - 46 * 24 * 3600)
    XCTAssertEqual(router.getOutboundStampCost(destinationHash: dest), 8)
    router.cleanOutboundStampCosts()
    XCTAssertNil(router.getOutboundStampCost(destinationHash: dest))
  }

  func testAFileFromAnEarlierReleaseStillLoads() throws {
    try writeFile([(dest, .double(12))])
    XCTAssertEqual(router().getOutboundStampCost(destinationHash: dest), 12)
  }

  func testAnUnchangedCostIsSavedByTheJobNotEveryAnnounce() throws {
    let router = router()
    router.setOutboundStampCost(destinationHash: dest, stampCost: 8)
    try FileManager.default.removeItem(at: file)

    router.setOutboundStampCost(destinationHash: dest, stampCost: 8)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    router.cleanOutboundStampCosts()
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the job saves it")

    // Reference cell: a changed cost is saved at once.
    try FileManager.default.removeItem(at: file)
    router.setOutboundStampCost(destinationHash: dest, stampCost: 9)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
  }

}
