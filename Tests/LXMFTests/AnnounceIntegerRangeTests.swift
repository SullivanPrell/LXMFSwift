//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXMFSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import Foundation
import ReticulumSwift
import Testing

@testable import LXMF

/// Announce integers outside the range of `Int`.
///
/// Python's `int()` has no upper bound (`LXMF.py:231-244`), so any sender can put one in an
/// announce.
@Suite("Announce integers outside Int's range")
struct AnnounceIntegerRangeTests {

  static func pnAppData(stampCost: MsgPack.Value) -> Data {
    MsgPack.encode(
      .array([
        .bool(false), .uint(1_700_000_000), .bool(true), .uint(256), .uint(10_240),
        .array([stampCost, .uint(3), .uint(18)]), .map([]),
      ]))
  }

  @Test("a delivery announce's stamp cost above Int.max reads as no cost")
  func deliveryStampCostAboveIntMax() {
    let appData = MsgPack.encode(.array([.bytes(Data("n".utf8)), .uint(UInt64.max), .array([])]))
    #expect(stampCostFromAppData(appData) == nil)
  }

  @Test("a delivery announce's stamp cost in range still reads")
  func deliveryStampCostInRange() {
    let appData = MsgPack.encode(.array([.bytes(Data("n".utf8)), .uint(8), .array([])]))
    #expect(stampCostFromAppData(appData) == 8)
  }

  @Test("a propagation node's stamp cost above Int.max reads as no cost")
  func pnStampCostAboveIntMax() {
    #expect(pnStampCostFromAppData(Self.pnAppData(stampCost: .uint(UInt64.max))) == nil)
  }

  @Test("a propagation node announce with a cost outside Int's range is rejected")
  func pnAnnounceUnsignedAboveIntMax() {
    #expect(PropagationNodeAnnounce(appData: Self.pnAppData(stampCost: .uint(UInt64.max))) == nil)
  }

  @Test(
    "a propagation node announce with a float cost Int can't hold is rejected",
    arguments: [1e300, -1e300, Double.infinity, Double.nan])
  func pnAnnounceFloatOutOfRange(cost: Double) {
    #expect(PropagationNodeAnnounce(appData: Self.pnAppData(stampCost: .double(cost))) == nil)
  }

  @Test("a fractional cost truncates toward zero, as Python's int() does")
  func pnAnnounceFractionalCost() {
    let announce = PropagationNodeAnnounce(appData: Self.pnAppData(stampCost: .double(16.9)))
    #expect(announce?.stampCost == 16)
  }
}
