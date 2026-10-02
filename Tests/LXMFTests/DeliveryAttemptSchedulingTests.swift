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

/// How the outbound queue spaces, counts, and ends delivery attempts, against LXMF 1.2.0.
///
/// `schedule_attempt` spaces each attempt by the destination's round trip and lowers a
/// message's attempt limit on a slow medium. `attempt_due` lets a message waiting on a path go
/// when the path arrives. A message past its limit fails only once its last attempt is due
/// (`LXMRouter.py:1794-1813`, `:2805-2997`). Every expected delay and limit below was read from
/// LXMF 1.2.0's own methods on RNS 1.5.5.
@Suite("Delivery attempt scheduling")
struct DeliveryAttemptSchedulingTests {

  // MARK: - schedule_attempt, attempt_limit, attempt_due

  @Test(
    "An attempt is spaced by the round trip, and a slow medium lowers the attempt limit",
    arguments: [
      (1_000_000, false, 10.0, 5),
      (1_000_000, true, 7.0, 5),
      (2000, false, 10.0, 5),
      (1999, false, 10.002_001, 5),
      (1200, false, 12.666_667, 4),
      (1200, true, 12.666_667, 4),
    ])
  func scheduleFollowsTheMedium(
    bitrate: Int, pathRequest: Bool, delay: Double, limit: Int
  ) throws {
    let node = try SingleNode()
    node.setSlowestBitrate(bitrate)
    let message = try node.enqueueMessage(method: .direct)
    let before = Date().timeIntervalSince1970

    node.router.scheduleAttempt(
      message, destinationHash: node.remoteDestination.hash, pathRequest: pathRequest)

    #expect(abs(message.nextDeliveryAttempt - before - delay) < 0.1)
    #expect(message.maxDeliveryAttempts == limit)
    #expect(message.awaitingPath == pathRequest)
  }

  @Test(
    "The attempt limit for a long round trip rounds half to even, as Python's round does",
    arguments: [
      (6.0, 5), (10.0, 5), (10.5, 5), (11.111_111_111_111_11, 4), (12.0, 4),
      (14.285_714_285_714_286, 4), (20.0, 3), (1000.0, 3),
    ])
  func attemptLimitForRoundTrip(roundTrip: Double, limit: Int) {
    #expect(LXMRouter.deliveryAttemptLimit(roundTrip: roundTrip) == limit)
  }

  @Test("A message without its own limit takes MAX_DELIVERY_ATTEMPTS")
  func attemptLimitDefaults() throws {
    let node = try SingleNode()
    let message = try node.enqueueMessage(method: .direct)
    #expect(node.router.attemptLimit(message) == LXMRouter.maxDeliveryAttempts)
    message.maxDeliveryAttempts = 3
    #expect(node.router.attemptLimit(message) == 3)
  }

  @Test("An attempt is due once its time passes, or early when an awaited path arrives")
  func attemptDue() throws {
    let pair = try AnnouncedPair()
    let message = try pair.message(method: .direct)
    let known = pair.destination.hash
    let unknown = Data(repeating: 0x5A, count: 16)

    message.nextDeliveryAttempt = Date().timeIntervalSince1970 - 1
    #expect(pair.router.attemptDue(message, destinationHash: unknown))

    message.nextDeliveryAttempt = Date().timeIntervalSince1970 + 60
    #expect(!pair.router.attemptDue(message, destinationHash: known))
    message.awaitingPath = true
    #expect(pair.router.attemptDue(message, destinationHash: known))
    #expect(!pair.router.attemptDue(message, destinationHash: unknown))
  }

  // MARK: - Opportunistic

  @Test("A second pathless path request inside the wait is suppressed")
  func pathlessOpportunisticRequestsOnce() throws {
    let node = try SingleNode()
    let message = try node.enqueueMessage(method: .opportunistic)

    for _ in 0..<3 {
      message.nextDeliveryAttempt = 0
      node.router.processOutbound()
    }

    #expect(message.deliveryAttempts == 3)
    #expect(node.iface.sentPathRequests().count == 1)
    #expect(message.awaitingPath)
  }

  @Test("A message past its attempt limit fails only once its last attempt is due")
  func exhaustedMessageFailsWhenDue() throws {
    let node = try SingleNode()
    let message = try node.enqueueMessage(method: .opportunistic)
    message.deliveryAttempts = LXMRouter.maxDeliveryAttempts + 1
    message.nextDeliveryAttempt = Date().timeIntervalSince1970 + 60

    node.router.processOutbound()
    #expect(message.state != .failed)

    message.nextDeliveryAttempt = 0
    node.router.processOutbound()
    #expect(message.state == .failed)
  }

  @Test("A send records whether the destination had a path")
  func sendRecordsThePath() throws {
    let pair = try AnnouncedPair()
    let message = try pair.message(method: .opportunistic)

    pair.router.processOutbound()

    #expect(message.deliveryAttempts == 1)
    #expect(message.sentOnPath)
    #expect(pair.sentTo(pair.destination.hash) == 1)
  }

  @Test("A path is rediscovered only after an attempt went out on it")
  func noRediscoveryWithoutASendOnThePath() throws {
    let pair = try AnnouncedPair()
    let message = try pair.message(method: .opportunistic)
    message.deliveryAttempts = LXMRouter.maxPathlessTries + 1
    message.sentOnPath = false

    pair.router.processOutbound()

    #expect(pair.transportA.hasPath(to: pair.destination.hash))
    #expect(pair.sentTo(pair.destination.hash) == 1)
    #expect(message.deliveryAttempts == LXMRouter.maxPathlessTries + 2)
  }

  @Test("A rediscovery waits on a path request already pending, without dropping the path")
  func rediscoveryWaitsOnAPendingRequest() throws {
    let pair = try AnnouncedPair()
    let message = try pair.message(method: .opportunistic)
    message.deliveryAttempts = LXMRouter.maxPathlessTries + 1
    message.sentOnPath = true
    pair.router.seedPathRequestTime(pair.destination.hash, Date().timeIntervalSince1970)
    let before = Date().timeIntervalSince1970

    pair.router.processOutbound()

    #expect(pair.transportA.hasPath(to: pair.destination.hash))
    #expect(pair.ifaceA.sentPathRequests().isEmpty)
    #expect(message.awaitingPath)
    #expect(!message.sentOnPath)
    #expect(abs(message.nextDeliveryAttempt - before - LXMRouter.pathRequestWait) < 0.5)
  }

  @Test("A send that throws fails the message")
  func throwingSendFailsTheMessage() throws {
    let pair = try AnnouncedPair()
    pair.transportA.restore(ratchet: Data([1, 2, 3]), forDestination: pair.destination.hash)
    let message = try pair.message(method: .opportunistic)
    var failed = false
    message.onFailed = { _ in failed = true }

    pair.router.processOutbound()

    #expect(message.state == .failed)
    #expect(failed)
    #expect(!pair.router.pendingOutbound.contains { $0 === message })
  }

  @Test("Sending to a destination with no path requests one and waits for it")
  func sendRequestsAnUnknownPathFirst() throws {
    let node = try SingleNode()
    let message = LXMessage(
      destination: node.remoteDestination, source: node.sourceDestination,
      content: "unknown path", desiredMethod: .opportunistic)
    let before = Date().timeIntervalSince1970

    try node.router.send(message)

    #expect(node.iface.sentPathRequests().count == 1)
    #expect(message.deliveryAttempts == 0)
    #expect(message.awaitingPath)
    #expect(abs(message.nextDeliveryAttempt - before - LXMRouter.pathRequestWait) < 0.5)
  }

  // MARK: - Direct and propagated

  @Test("A direct message to a pathless destination fails on its fifth attempt")
  func pathlessDirectFailsOnTheFifthAttempt() throws {
    let node = try SingleNode()
    let message = try node.enqueueMessage(method: .direct)

    var passes = 0
    while message.state != .failed && passes < 20 {
      message.nextDeliveryAttempt = 0
      node.router.processOutbound()
      passes += 1
    }

    #expect(message.state == .failed)
    #expect(message.deliveryAttempts == LXMRouter.maxDeliveryAttempts)
    #expect(passes == LXMRouter.maxDeliveryAttempts)
    #expect(node.iface.sentPathRequests().count == 1)
  }

  @Test("A propagated message to a pathless node fails on its fifth attempt")
  func pathlessPropagatedFailsOnTheFifthAttempt() throws {
    let node = try SingleNode()
    node.router.outboundPropagationNode = Data(repeating: 0xAB, count: 16)
    let message = try node.enqueueMessage(method: .propagated)

    var passes = 0
    while message.state != .failed && passes < 20 {
      message.nextDeliveryAttempt = 0
      node.router.processOutbound()
      passes += 1
    }

    #expect(message.state == .failed)
    #expect(message.deliveryAttempts == LXMRouter.maxDeliveryAttempts)
  }

  @Test("A direct link that closed before activating re-requests the path and reschedules")
  func closedDirectLinkReschedules() throws {
    let pair = try AnnouncedPair()
    pair.ifaceA.isBlackholed = true
    let message = try pair.message(method: .direct)

    pair.router.processOutbound()
    let link = try #require(pair.router.directLinks[pair.destination.hash])
    #expect(message.deliveryAttempts == 1)
    try link.teardown()
    pair.ifaceA.clearSent()
    let before = Date().timeIntervalSince1970

    pair.router.processOutbound()

    #expect(pair.router.directLinks[pair.destination.hash] == nil)
    #expect(pair.ifaceA.sentPathRequests().count == 1)
    #expect(message.deliveryAttempts == 1)
    #expect(abs(message.nextDeliveryAttempt - before - LXMRouter.deliveryRetryWait) < 0.5)
  }

  // MARK: - Announce triggers

  @Test("A delivery announce brings forward only messages waiting on a path")
  func deliveryAnnounceTriggersOnlyAwaitingMessages() throws {
    let node = try SingleNode()
    let waiting = try node.enqueueMessage(method: .direct)
    let scheduled = try node.enqueueMessage(method: .direct)
    let later = Date().timeIntervalSince1970 + 60
    waiting.nextDeliveryAttempt = later
    waiting.awaitingPath = true
    scheduled.nextDeliveryAttempt = later

    node.router.handleAnnounceForDestination(node.remoteDestination.hash)

    #expect(waiting.nextDeliveryAttempt < later)
    #expect(scheduled.nextDeliveryAttempt == later)
  }

  @Test("A propagation node announce brings forward only messages waiting on a path")
  func propagationAnnounceTriggersOnlyAwaitingMessages() throws {
    let node = try SingleNode()
    node.router.outboundPropagationNode = Data(repeating: 0xAB, count: 16)
    let waiting = try node.enqueueMessage(method: .propagated)
    let scheduled = try node.enqueueMessage(method: .propagated)
    let later = Date().timeIntervalSince1970 + 60
    waiting.nextDeliveryAttempt = later
    waiting.awaitingPath = true
    scheduled.nextDeliveryAttempt = later

    node.router.triggerPropagatedOutbound()

    #expect(waiting.nextDeliveryAttempt < later)
    #expect(scheduled.nextDeliveryAttempt == later)
  }
}

// MARK: - Harness

/// A router on transport A, and a delivery destination on transport B that A has learned from
/// an announce, so A holds a path to it and can recall its identity.
final class AnnouncedPair {
  let transportA = Transport()
  let transportB = Transport()
  let ifaceA = PeerSyncLoopInterface(name: "a")
  let ifaceB = PeerSyncLoopInterface(name: "b")
  let router: LXMRouter
  let destination: Destination
  let source: Destination

  init() throws {
    ifaceA.paired = ifaceB
    ifaceB.paired = ifaceA
    transportA.register(interface: ifaceA)
    transportB.register(interface: ifaceB)

    let identityB = Identity()
    destination = try Destination(
      identity: identityB, direction: .in, kind: .single,
      appName: "lxmf", aspects: ["delivery"])
    transportB.ownerIdentity = identityB
    transportB.register(destination: destination)
    _ = try transportB.announce(destination: destination)

    let deadline = Date().addingTimeInterval(2)
    while !transportA.hasPath(to: destination.hash) && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    guard transportA.hasPath(to: destination.hash) else { throw PairError.noPath }

    router = LXMRouter(transport: transportA)
    source = try Destination(
      identity: Identity(), direction: .in, kind: .single,
      appName: "lxmf", aspects: ["delivery"])
    ifaceA.clearSent()
  }

  /// Packs a small message to `destination` and queues it without the enqueue-time pass.
  func message(method: LXMessage.Method) throws -> LXMessage {
    let message = LXMessage(
      destination: destination, source: source,
      content: "scheduling", desiredMethod: method)
    try message.pack()
    message.state = .outbound
    router.testInjectPendingOutbound(message)
    return message
  }

  /// The number of packets A sent to `destinationHash`.
  func sentTo(_ destinationHash: Data) -> Int {
    ifaceA.sent.filter { $0.destinationHash == destinationHash }.count
  }

  enum PairError: Error { case noPath }
}
