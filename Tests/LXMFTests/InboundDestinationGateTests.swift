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

/// The inbound gate's two checks that Python makes without an `if`.
///
/// `lxmf_delivery` reads `self.delivery_destinations[message.destination_hash].stamp_cost`
/// inside a `try`, so a message addressed to a destination the router doesn't host raises and
/// is dropped (`LXMRouter.py:2192`, `:2259-2262`). Its duplicate claim is one step on the
/// store (`conditionally_claim_delivered`, `:2239`).
final class InboundDestinationGateTests: XCTestCase {

  private func makeRouter() throws -> (router: LXMRouter, src: Destination, dst: Destination) {
    let transport = Transport()
    let dstId = Identity()
    let router = LXMRouter(transport: transport)
    try router.register(identity: dstId, transport: transport)
    let src = try Destination(
      identity: Identity(), direction: .in, kind: .single, appName: "lxmf",
      aspects: ["delivery"])
    let dst = try Destination(
      identity: dstId, direction: .out, kind: .single, appName: "lxmf", aspects: ["delivery"])
    return (router, src, dst)
  }

  /// A message for a destination the router doesn't host is dropped.
  ///
  /// A link carries the packed message whole, destination hash included, so a sender can put
  /// any hash there. With a stamp cost on the real destination, a made-up hash found no cost
  /// and skipped enforcement.
  func testAMessageForADestinationThisRouterDoesNotHostIsDropped() throws {
    let (router, src, dst) = try makeRouter()
    _ = router.setInboundStampCost(destinationHash: dst.hash, stampCost: 8)
    router.enforceStamps()
    let elsewhere = try Destination(
      identity: Identity(), direction: .out, kind: .single, appName: "lxmf",
      aspects: ["delivery"])
    let msg = LXMessage(destination: elsewhere, source: src, content: "no stamp")
    try msg.pack()

    var delivered = false
    router.onMessageReceived = { _ in delivered = true }
    XCTAssertFalse(router.finalizeInboundDelivery(msg))
    XCTAssertFalse(delivered, "a message for an unhosted destination must not reach the app")

    // Reference cell: the same unstamped message to the hosted destination is dropped by the
    // stamp check, and with enforcement off it is delivered, so the gate above is what
    // dropped the foreign one.
    router.ignoreStamps()
    let hosted = LXMessage(destination: dst, source: src, content: "no stamp")
    try hosted.pack()
    XCTAssertTrue(router.finalizeInboundDelivery(hosted))
  }

  /// Every concurrent copy of one message is delivered once.
  ///
  /// Two threads both passed `hasMessage` before either recorded the ID.
  func testConcurrentCopiesOfOneMessageAreDeliveredOnce() throws {
    let (router, src, dst) = try makeRouter()
    let lock = NSLock()
    var count = 0
    router.onMessageReceived = { _ in
      lock.lock()
      count += 1
      lock.unlock()
    }
    for round in 0..<50 {
      let msg = LXMessage(destination: dst, source: src, content: "copy \(round)")
      try msg.pack()
      DispatchQueue.concurrentPerform(iterations: 8) { _ in
        router.finalizeInboundDelivery(msg)
      }
    }
    XCTAssertEqual(count, 50)
  }
}
