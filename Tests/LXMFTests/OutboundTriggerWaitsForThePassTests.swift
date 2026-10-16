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
import XCTest

@testable import LXMF

/// A trigger that arrives during an outbound pass runs another pass once that one ends.
///
/// Python waits out the running pass (`Handlers.py:29`, `:51`, `LXMRouter.py:1859`), so the
/// message doesn't wait for the next jobs tick. Each test ends long before the router's first
/// jobs tick, 4 s after it starts, so only the trigger can run the second pass.
final class OutboundTriggerWaitsForThePassTests: XCTestCase {

  func testADeliveryAnnounceDuringAPass() throws {
    let node = try SingleNode()
    try duringAPass(node) {
      let waiting = try node.enqueueMessage(method: .opportunistic)
      waiting.awaitingPath = true
      node.router.handleAnnounceForDestination(node.remoteDestination.hash)
    }
  }

  func testAPropagationNodeAnnounceDuringAPass() throws {
    let node = try SingleNode()
    try duringAPass(node) {
      let waiting = try node.enqueueMessage(method: .propagated)
      waiting.awaitingPath = true
      node.router.triggerPropagatedOutbound()
    }
  }

  func testAMessageSentDuringAPass() throws {
    let node = try SingleNode()
    try duringAPass(node) {
      try node.router.send(
        LXMessage(
          destination: node.remoteDestination, source: node.sourceDestination,
          content: "sent during a pass", desiredMethod: .direct))
    }
  }

  /// Holds a pass open, runs `trigger`, ends the pass, and expects another pass within 1 s.
  private func duringAPass(_ node: SingleNode, trigger: () throws -> Void) throws {
    let entered = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    let holder = try node.enqueueMessage(method: .opportunistic)
    holder.state = .delivered
    holder.onDelivery = { _ in
      entered.signal()
      gate.wait()
    }
    DispatchQueue.global().async { node.router.processOutbound() }
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

    // Queued after the held pass took its snapshot, so only a later pass delivers it.
    let marker = try node.enqueueMessage(method: .opportunistic)
    marker.state = .delivered
    let followed = expectation(description: "a pass after the held one")
    marker.onDelivery = { _ in followed.fulfill() }

    try trigger()
    // Lets a trigger that dispatches its pass reach the held one first.
    Thread.sleep(forTimeInterval: 0.1)
    gate.signal()
    wait(for: [followed], timeout: 1)
  }
}
