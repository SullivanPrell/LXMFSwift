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

/// The deferred stamp queue, against LXMF 1.2.0 at `c3ff2d6`: `handle_outbound` parks a message
/// that needs a stamp in `pending_deferred_stamps` (`LXMRouter.py:1833-1864`), and
/// `process_deferred_stamps` stamps it off the caller's thread (`:2648-2737`).
@Suite("Deferred stamps")
struct DeferredStampTests {

  /// A cost the search can't clear before the test cancels it.
  static let slowCost = 14

  @Test("send returns before the stamp exists, and the message waits in the deferred store")
  func sendReturnsBeforeTheStamp() throws {
    let node = try SingleNode()
    let message = node.message(stampCost: Self.slowCost)

    try node.router.send(message)

    #expect(message.stamp == nil)
    #expect(message.messageID != nil)
    #expect(message.state == .outbound)
    #expect(node.router.pendingDeferredStamps.contains { $0 === message })
    #expect(!node.router.pendingOutbound.contains { $0 === message })
    try node.cancel(message)
  }

  @Test("A deferred message goes out stamped, with the hash it had when send returned")
  func deferredMessageGoesOutStamped() throws {
    let node = try SingleNode()
    let message = node.message(stampCost: 2)

    try node.router.send(message)
    let id = try #require(message.messageID)
    try waitUntil { node.router.pendingOutbound.contains { $0 === message } }

    #expect(!node.router.pendingDeferredStamps.contains { $0 === message })
    #expect(!message.deferStamp)
    #expect(message.messageID == id)
    let wire = try LXMessage.unpack(try #require(message.packed))
    #expect(wire.validateStamp(targetCost: 2))
  }

  @Test("cancelOutbound stops a deferred stamp and fails the message")
  func cancelDropsADeferredMessage() throws {
    let node = try SingleNode()
    let message = node.message(stampCost: Self.slowCost)
    let failed = LockedCount()
    message.onFailed = { _ in failed.increment() }

    try node.router.send(message)
    try node.cancel(message)
    try waitUntil { failed.value == 1 }

    #expect(message.state == .cancelled)
    #expect(message.stampGenerationFailed)
    #expect(!node.router.pendingOutbound.contains { $0 === message })
  }

  @Test("An outbound ticket skips the queue and stamps at once (LXMRouter.py:1833-1835)")
  func ticketSkipsTheQueue() throws {
    let node = try SingleNode()
    let ticket = Data(repeating: 0x5C, count: LXMessage.ticketLength)
    node.router.rememberTicket(
      destinationHash: node.remoteDestination.hash,
      expiry: Date().timeIntervalSince1970 + 3600, ticket: ticket)
    let message = node.message(stampCost: Self.slowCost)

    try node.router.send(message)

    #expect(!message.deferStamp)
    let id = try #require(message.messageID)
    #expect(message.stamp == Hashes.truncatedHash(ticket + id))
    #expect(!node.router.pendingDeferredStamps.contains { $0 === message })
    #expect(node.router.pendingOutbound.contains { $0 === message })
  }

  @Test("A message with no stamp cost skips the queue (LXMRouter.py:1854-1856)")
  func noStampCostSkipsTheQueue() throws {
    let node = try SingleNode()
    let message = node.message(stampCost: nil)

    try node.router.send(message)

    #expect(!message.deferStamp)
    #expect(!node.router.pendingDeferredStamps.contains { $0 === message })
    #expect(node.router.pendingOutbound.contains { $0 === message })
  }

  @Test("getOutboundProgress finds a message waiting for its stamp (LXMRouter.py:1871-1873)")
  func progressCoversDeferredMessages() throws {
    let node = try SingleNode()
    let message = node.message(stampCost: Self.slowCost)

    try node.router.send(message)

    #expect(node.router.getOutboundProgress(lxmHash: try #require(message.hash)) == 0)
    try node.cancel(message)
  }

  @Test("A propagated message waits in the deferred store for its stamps (LXMRouter.py:1858)")
  func propagatedMessageIsDeferred() throws {
    let node = try SingleNode()
    node.router.outboundPropagationNode = Data(repeating: 0x9D, count: 16)
    let message = node.message(stampCost: Self.slowCost, method: .propagated)

    try node.router.send(message)

    #expect(message.stamp == nil)
    #expect(node.router.pendingDeferredStamps.contains { $0 === message })
    #expect(!node.router.pendingOutbound.contains { $0 === message })
    try node.cancel(message)
  }

  @Test("A propagated message with no stamp cost still passes through the queue to delivery")
  func propagatedMessageLeavesTheQueue() throws {
    let node = try SingleNode()
    node.router.outboundPropagationNode = Data(repeating: 0x9D, count: 16)
    let message = node.message(stampCost: nil, method: .propagated)

    try node.router.send(message)
    try waitUntil { node.router.pendingOutbound.contains { $0 === message } }

    #expect(!message.deferPropagationStamp)
    #expect(!node.router.pendingDeferredStamps.contains { $0 === message })
  }
}

extension SingleNode {
  /// An unpacked message to the remote destination.
  fileprivate func message(stampCost: Int?, method: LXMessage.Method = .direct) -> LXMessage {
    let message = LXMessage(
      destination: remoteDestination, source: sourceDestination,
      content: "deferred stamp", desiredMethod: method)
    message.stampCost = stampCost
    return message
  }

  /// Cancel `message` and wait for the stamp job to drop it.
  fileprivate func cancel(_ message: LXMessage) throws {
    router.cancelOutbound(messageID: try #require(message.messageID))
    try waitUntil { !router.pendingDeferredStamps.contains { $0 === message } }
  }
}

private final class LockedCount: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

private struct TimedOut: Error {}

private func waitUntil(timeout: TimeInterval = 60, _ condition: () -> Bool) throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() {
    guard Date() < deadline else { throw TimedOut() }
    Thread.sleep(forTimeInterval: 0.01)
  }
}
