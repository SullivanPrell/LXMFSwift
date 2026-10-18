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

/// The outbound queue hold on slow paths, against LXMF 1.2.1 (commit `5745f85`).
///
/// A path is slow when its round trip is above `deliveryRetryWait`. On a slow path the router
/// keeps one message in flight and holds every queued message that would add to the load
/// (LXMF 1.2.1 `LXMRouter.py:1805-1860`, `:2854-3049`). Every expected value below was printed by
/// `scripts/capture-outbound-hold-vectors.py` from LXMF 1.2.1's own methods. Each section name is
/// the script's.
@Suite("Outbound hold on slow paths")
struct OutboundHoldTests {

  // MARK: - schedule_attempt

  @Test(
    "schedule_attempt: the delay spans the jitter, and a long round trip sets a receipt timeout",
    arguments: scheduleRows)
  func scheduleAttempt(row: ScheduleRow) {
    for (uniform, delay) in [(lowest, row.delayMin), (highest, row.delayMax)] {
      let schedule = LXMRouter.attemptSchedule(
        roundTrip: row.roundTrip, pathRequest: row.pathRequest,
        deliveryAttempts: row.attempts, uniform: uniform)
      #expect(abs(schedule.delay - delay) < 1e-9)
      #expect(schedule.limit == row.limit)
      if let expected = row.receiptTimeout {
        #expect(abs((schedule.receiptTimeout ?? 0) - expected) < 1e-9)
      } else {
        #expect(schedule.receiptTimeout == nil)
      }
    }
  }

  @Test(
    "schedule_attempt: the router schedules from the medium's round trip",
    arguments: [
      // (bitrate, path request, attempts) -> round trip 10 or 11 s, rows of section 1.
      (2000, false, 0, 12.0, 5, 76.0),
      (1600, false, 1, 13.5, 5, 71.5),
      (1600, true, 0, 13.5, 5, 85.0),
    ])
  func scheduleAttemptThroughTheRouter(
    bitrate: Int, pathRequest: Bool, attempts: Int, delay: Double, limit: Int,
    receiptTimeout: Double
  ) throws {
    let node = try SingleNode()
    node.setSlowestBitrate(bitrate)
    node.router.uniform = highest
    let message = try node.enqueueMessage(method: .direct)
    message.deliveryAttempts = attempts
    let before = Date().timeIntervalSince1970

    node.router.scheduleAttempt(
      message, destinationHash: node.remoteDestination.hash, pathRequest: pathRequest)

    #expect(abs(message.nextDeliveryAttempt - before - delay) < 0.1)
    #expect(message.maxDeliveryAttempts == limit)
    #expect(abs((message.receiptTimeout ?? 0) - receiptTimeout) < 1e-6)
  }

  // MARK: - slow_path

  @Test(
    "slow_path: a round trip is slow when it's strictly greater than 10 s",
    arguments: [(nil, false), (1_000_000, false), (2000, false), (1999, true), (1600, true)]
      as [(Int?, Bool)])
  func slowPathThreshold(bitrate: Int?, slow: Bool) throws {
    let node = try SingleNode()
    if let bitrate { node.setSlowestBitrate(bitrate) }
    #expect(node.router.slowPath(node.remoteDestination.hash) == slow)
  }

  @Test(
    "slow_path: an answer is kept for less than PROCESSING_INTERVAL",
    arguments: [(3.9, true), (4.0, false), (4.1, false)])
  func slowPathCacheExpiry(offset: TimeInterval, slow: Bool) throws {
    let node = try SingleNode()
    let destination = node.remoteDestination.hash
    var now: TimeInterval = 1000
    node.router.clock = { now }
    node.setSlowestBitrate(1600)
    #expect(node.router.slowPath(destination))

    node.setSlowestBitrate(1_000_000)
    now += offset
    #expect(node.router.slowPath(destination) == slow)
  }

  @Test(
    "slow_path: the cache empties when it holds more than 256 entries",
    arguments: [(255, true), (256, true), (257, false)])
  func slowPathCacheCap(entries: Int, kept: Bool) throws {
    let node = try SingleNode()
    node.router.clock = { 1000 }
    let probe = node.remoteDestination.hash
    node.router.seedSlowPath(probe, true)
    for i in 1..<entries {
      node.router.seedSlowPath(Data([UInt8(i & 0xFF), UInt8(i >> 8)] + [UInt8](repeating: 0, count: 14)), true)
    }

    _ = node.router.slowPath(Data(repeating: 0xEE, count: 16))

    // The probe's real round trip is fast, so only a cached entry answers slow.
    #expect(node.router.slowPath(probe) == kept)
  }

  // MARK: - slow_path_held

  @Test("slow_path_held: which queued messages wait", arguments: heldLayouts)
  func slowPathHeld(layout: HeldLayout) throws {
    let node = try SingleNode()
    node.router.clock = { 1000 }
    let source = node.sourceDestination
    let destinations = try [Target.a, .b, .n].reduce(into: [Target: Destination]()) {
      $0[$1] = try Destination(
        identity: Identity(), direction: .in, kind: .single, appName: "lxmf",
        aspects: ["delivery"])
    }
    let propagationNode = try #require(destinations[.n])
    node.router.outboundPropagationNode = propagationNode.hash
    for (target, destination) in destinations {
      node.router.seedSlowPath(destination.hash, layout.slow.contains(target))
    }
    let queue = layout.queue.map { entry in
      let message = LXMessage(
        destination: destinations[entry.target]!, source: source, content: "held")
      message.method = entry.method
      message.state = entry.state
      message.sentOnSlowPath = entry.flag
      node.router.testInjectPendingOutbound(message)
      return message
    }

    let held = queue.map { message in
      let target = message.method == .propagated ? propagationNode.hash : message.destinationHash
      return node.router.slowPathHeld(message, target: target)
    }

    #expect(held == layout.queue.map(\.held))
  }

  // MARK: - The hold in the outbound pass

  @Test("process_outbound: a second message to a slow target waits for the first")
  func secondMessageToASlowTargetWaits() throws {
    let node = try SingleNode()
    node.setSlowestBitrate(1200)
    let first = try node.enqueueMessage(method: .direct)
    let second = try node.enqueueMessage(method: .direct)

    node.router.processOutbound()

    #expect(first.deliveryAttempts == 1)
    #expect(second.deliveryAttempts == 0)
  }

  @Test("process_outbound: a message in flight on a slow path holds another target's message")
  func inFlightMessageHoldsAnotherTarget() throws {
    let node = try SingleNode()
    node.setSlowestBitrate(1200)
    let inFlight = try node.enqueueMessage(method: .opportunistic)
    inFlight.state = .sent
    inFlight.sentOnSlowPath = true
    inFlight.nextDeliveryAttempt = Date().timeIntervalSince1970 + 60
    let other = try node.enqueueMessage(method: .opportunistic, to: node.otherDestination())

    node.router.processOutbound()

    #expect(other.deliveryAttempts == 0)
  }

  @Test("process_outbound: a held message doesn't fail, and fails once released")
  func heldMessageFailsOnlyOnceReleased() throws {
    let node = try SingleNode()
    node.setSlowestBitrate(1200)
    let inFlight = try node.enqueueMessage(method: .opportunistic)
    inFlight.state = .sent
    inFlight.sentOnSlowPath = true
    inFlight.nextDeliveryAttempt = Date().timeIntervalSince1970 + 60
    let exhausted = try node.enqueueMessage(method: .opportunistic, to: node.otherDestination())
    exhausted.deliveryAttempts = LXMRouter.maxDeliveryAttempts + 1
    exhausted.nextDeliveryAttempt = 0

    node.router.processOutbound()
    #expect(exhausted.state == .outbound)

    inFlight.state = .delivered
    node.router.processOutbound()
    #expect(exhausted.state == .failed)
  }

  @Test(
    "process_outbound: a transfer starts only from OUTBOUND, without setting the flag",
    arguments: [LXMessage.Method.direct, .propagated])
  func transferStartsOnlyFromOutbound(method: LXMessage.Method) throws {
    let pair = try AnnouncedPair()
    let message = try pair.message(method: method)
    try pair.useActiveLink(for: method)
    pair.router.seedSlowPath(pair.target(for: method), true)
    message.state = .sent

    pair.router.processOutbound()

    #expect(message.state == .sent)
    #expect(!message.sentOnSlowPath)
  }

  @Test(
    "process_outbound: each branch records whether its attempt went out on a slow path",
    arguments: [LXMessage.Method.opportunistic, .direct, .propagated], [true, false])
  func attemptRecordsTheSlowPath(method: LXMessage.Method, slow: Bool) throws {
    let pair = try AnnouncedPair()
    let message = try pair.message(method: method)
    if method != .opportunistic { try pair.useActiveLink(for: method) }
    pair.router.seedSlowPath(pair.target(for: method), slow)

    pair.router.processOutbound()

    // A propagated transfer completes inside the pass on this wire.
    #expect(message.state != .outbound)
    #expect(message.sentOnSlowPath == slow)
  }

  @Test("LXMessage.send: an opportunistic receipt waits out the retry schedule")
  func opportunisticReceiptTimeout() throws {
    let pair = try AnnouncedPair()
    pair.ifaceA.bitrate = 1200
    pair.transportA.prioritizeInterfaces()
    let message = try pair.message(method: .opportunistic)

    pair.router.processOutbound()

    let receiptTimeout = try #require(message.receiptTimeout)
    let receipt = try #require(message.deliveryReceipt)
    #expect(receipt.timeout == receiptTimeout)
  }

  @Test("A link coming up runs a pass, so every message waiting on it goes out")
  func establishedLinkRunsAPass() throws {
    let pair = try AnnouncedPair()
    // This wire completes a handshake inside `Link.initiate`, so hold B's link proof for later.
    var proof: Packet?
    pair.ifaceB.dropOutbound = { packet in
      guard packet.packetType == .proof else { return false }
      proof = packet
      return true
    }
    let first = try pair.message(method: .direct)
    let second = try pair.message(method: .direct)

    pair.router.processOutbound()
    #expect(first.deliveryAttempts == 1)
    #expect(second.state == .outbound)

    pair.ifaceB.dropOutbound = nil
    let held = try Packet.unpack(try #require(proof).pack())
    pair.ifaceA.inboundHandler?(held, pair.ifaceA)

    try waitUntil { first.state == .sending && second.state == .sending }
  }

  // MARK: - outbound_concluded

  @Test("outbound_concluded: a message that didn't go out on a slow path starts no pass")
  func concludedWithoutTheFlag() throws {
    let node = try SingleNode()
    let message = try node.enqueueMessage(method: .direct)
    #expect(!node.router.outboundConcluded(message))
  }

  @Test("outbound_concluded: a message that went out on a slow path starts one pass")
  func concludedWithTheFlag() throws {
    let node = try SingleNode()
    let pass = node.passMarker()
    let message = try node.enqueueMessage(method: .direct)
    message.sentOnSlowPath = true

    #expect(node.router.outboundConcluded(message))
    #expect(pass.wait(timeout: .now() + 2) == .success)
  }

  // MARK: - __mark_delivered and __mark_propagated

  @Test(
    "__mark_delivered: delivers once, at progress 1.0, and concludes a slow-path message",
    arguments: [LXMessage.State.sending, .outbound, .sent])
  func markDelivered(from state: LXMessage.State) throws {
    let node = try SingleNode()
    let pass = node.passMarker()
    let message = try node.enqueueMessage(method: .direct)
    message.state = state
    message.sentOnSlowPath = true
    let deliveries = Counter()
    message.onDelivery = { _ in deliveries.increment() }

    node.router.markDelivered(message)
    node.router.markDelivered(message)

    #expect(message.state == .delivered)
    #expect(message.progress == 1.0)
    #expect(deliveries.value == 1)
    #expect(pass.wait(timeout: .now() + 2) == .success)
  }

  @Test("__mark_propagated: a completed propagation transfer marks the message once")
  func completedPropagationMarksTheMessage() throws {
    let pair = try AnnouncedPair()
    let message = try pair.message(method: .propagated)
    try pair.useActiveLink(for: .propagated)
    let deliveries = Counter()
    message.onDelivery = { _ in deliveries.increment() }

    pair.router.processOutbound()

    try waitUntil { deliveries.value == 1 }
    #expect(message.state == .delivered)
    #expect(message.progress == 1.0)
  }
}

// MARK: - Vectors

/// One row of the script's `schedule_attempt` section.
struct ScheduleRow: CustomTestStringConvertible {
  let pathRequest: Bool
  let roundTrip: Double
  let attempts: Int
  let limit: Int
  let delayMin: Double
  let delayMax: Double
  let receiptTimeout: Double?

  init(
    _ pathRequest: Bool, _ roundTrip: Double, _ attempts: Int, _ limit: Int,
    _ delayMin: Double, _ delayMax: Double, _ receiptTimeout: Double?
  ) {
    (self.pathRequest, self.roundTrip, self.attempts, self.limit) =
      (pathRequest, roundTrip, attempts, limit)
    (self.delayMin, self.delayMax, self.receiptTimeout) = (delayMin, delayMax, receiptTimeout)
  }

  var testDescription: String {
    "path request \(pathRequest), round trip \(roundTrip), attempts \(attempts)"
  }
}

private let lowest: (ClosedRange<Double>) -> Double = { $0.lowerBound }
private let highest: (ClosedRange<Double>) -> Double = { $0.upperBound }

/// `schedule_attempt`, from LXMF 1.2.1 (`LXMRouter.py:1805-1823`).
let scheduleRows: [ScheduleRow] = [
      ScheduleRow(false, 0, 0, 5, 10, 10, nil),
      ScheduleRow(false, 0, 1, 5, 10, 10, nil),
      ScheduleRow(false, 0, 3, 5, 10, 10, nil),
      ScheduleRow(false, 0, 6, 5, 10, 10, nil),
      ScheduleRow(false, 6, 0, 5, 10, 10, nil),
      ScheduleRow(false, 6, 1, 5, 10, 10, nil),
      ScheduleRow(false, 6, 3, 5, 10, 10, nil),
      ScheduleRow(false, 6, 6, 5, 10, 10, nil),
      ScheduleRow(false, 7, 0, 5, 10, 10, nil),
      ScheduleRow(false, 7, 1, 5, 10, 10, nil),
      ScheduleRow(false, 7, 3, 5, 10, 10, nil),
      ScheduleRow(false, 7, 6, 5, 10, 10, nil),
      ScheduleRow(false, 7.2, 0, 5, 10, 10.6, 67.6),
      ScheduleRow(false, 7.2, 1, 5, 10, 10.6, 57),
      ScheduleRow(false, 7.2, 3, 5, 10, 10.6, 35.8),
      ScheduleRow(false, 7.2, 6, 5, 10, 10.6, 14.6),
      ScheduleRow(false, 10, 0, 5, 10, 12, 76),
      ScheduleRow(false, 10, 1, 5, 10, 12, 64),
      ScheduleRow(false, 10, 3, 5, 10, 12, 40),
      ScheduleRow(false, 10, 6, 5, 10, 12, 16),
      ScheduleRow(false, 11, 0, 5, 11, 13.5, 85),
      ScheduleRow(false, 11, 1, 5, 11, 13.5, 71.5),
      ScheduleRow(false, 11, 3, 5, 11, 13.5, 44.5),
      ScheduleRow(false, 11, 6, 5, 11, 13.5, 17.5),
      ScheduleRow(false, 12, 0, 4, 12, 15, 79),
      ScheduleRow(false, 12, 1, 4, 12, 15, 64),
      ScheduleRow(false, 12, 3, 4, 12, 15, 34),
      ScheduleRow(false, 12, 6, 4, 12, 15, 19),
      ScheduleRow(false, 13.5, 0, 4, 13.5, 17.25, 90.25),
      ScheduleRow(false, 13.5, 1, 4, 13.5, 17.25, 73),
      ScheduleRow(false, 13.5, 3, 4, 13.5, 17.25, 38.5),
      ScheduleRow(false, 13.5, 6, 4, 13.5, 17.25, 21.25),
      ScheduleRow(false, 20, 0, 3, 20, 27, 112),
      ScheduleRow(false, 20, 1, 3, 20, 27, 85),
      ScheduleRow(false, 20, 3, 3, 20, 27, 31),
      ScheduleRow(false, 20, 6, 3, 20, 27, 31),
      ScheduleRow(false, 40, 0, 3, 40, 57, 232),
      ScheduleRow(false, 40, 1, 3, 40, 57, 175),
      ScheduleRow(false, 40, 3, 3, 40, 57, 61),
      ScheduleRow(false, 40, 6, 3, 40, 57, 61),
      ScheduleRow(false, 120, 0, 3, 120, 177, 712),
      ScheduleRow(false, 120, 1, 3, 120, 177, 535),
      ScheduleRow(false, 120, 3, 3, 120, 177, 181),
      ScheduleRow(false, 120, 6, 3, 120, 177, 181),
      ScheduleRow(true, 0, 0, 5, 7, 7, nil),
      ScheduleRow(true, 0, 1, 5, 7, 7, nil),
      ScheduleRow(true, 0, 3, 5, 7, 7, nil),
      ScheduleRow(true, 0, 6, 5, 7, 7, nil),
      ScheduleRow(true, 6, 0, 5, 7, 7, nil),
      ScheduleRow(true, 6, 1, 5, 7, 7, nil),
      ScheduleRow(true, 6, 3, 5, 7, 7, nil),
      ScheduleRow(true, 6, 6, 5, 7, 7, nil),
      ScheduleRow(true, 7, 0, 5, 7, 7, nil),
      ScheduleRow(true, 7, 1, 5, 7, 7, nil),
      ScheduleRow(true, 7, 3, 5, 7, 7, nil),
      ScheduleRow(true, 7, 6, 5, 7, 7, nil),
      ScheduleRow(true, 7.2, 0, 5, 7.2, 7.8, 67.6),
      ScheduleRow(true, 7.2, 1, 5, 7.2, 7.8, 57),
      ScheduleRow(true, 7.2, 3, 5, 7.2, 7.8, 35.8),
      ScheduleRow(true, 7.2, 6, 5, 7.2, 7.8, 14.6),
      ScheduleRow(true, 10, 0, 5, 10, 12, 76),
      ScheduleRow(true, 10, 1, 5, 10, 12, 64),
      ScheduleRow(true, 10, 3, 5, 10, 12, 40),
      ScheduleRow(true, 10, 6, 5, 10, 12, 16),
      ScheduleRow(true, 11, 0, 5, 11, 13.5, 85),
      ScheduleRow(true, 11, 1, 5, 11, 13.5, 71.5),
      ScheduleRow(true, 11, 3, 5, 11, 13.5, 44.5),
      ScheduleRow(true, 11, 6, 5, 11, 13.5, 17.5),
      ScheduleRow(true, 12, 0, 4, 12, 15, 79),
      ScheduleRow(true, 12, 1, 4, 12, 15, 64),
      ScheduleRow(true, 12, 3, 4, 12, 15, 34),
      ScheduleRow(true, 12, 6, 4, 12, 15, 19),
      ScheduleRow(true, 13.5, 0, 4, 13.5, 17.25, 90.25),
      ScheduleRow(true, 13.5, 1, 4, 13.5, 17.25, 73),
      ScheduleRow(true, 13.5, 3, 4, 13.5, 17.25, 38.5),
      ScheduleRow(true, 13.5, 6, 4, 13.5, 17.25, 21.25),
      ScheduleRow(true, 20, 0, 3, 20, 27, 112),
      ScheduleRow(true, 20, 1, 3, 20, 27, 85),
      ScheduleRow(true, 20, 3, 3, 20, 27, 31),
      ScheduleRow(true, 20, 6, 3, 20, 27, 31),
      ScheduleRow(true, 40, 0, 3, 40, 57, 232),
      ScheduleRow(true, 40, 1, 3, 40, 57, 175),
      ScheduleRow(true, 40, 3, 3, 40, 57, 61),
      ScheduleRow(true, 40, 6, 3, 40, 57, 61),
      ScheduleRow(true, 120, 0, 3, 120, 177, 712),
      ScheduleRow(true, 120, 1, 3, 120, 177, 535),
      ScheduleRow(true, 120, 3, 3, 120, 177, 181),
      ScheduleRow(true, 120, 6, 3, 120, 177, 181),
]

enum Target { case a, b, n }

/// One queued message of a `slow_path_held` layout, with the result the script printed for it.
struct Queued {
  let state: LXMessage.State
  let method: LXMessage.Method
  let target: Target
  let flag: Bool
  let held: Bool

  init(
    _ state: LXMessage.State, _ method: LXMessage.Method, _ target: Target, _ flag: Bool,
    _ held: Bool
  ) {
    (self.state, self.method, self.target, self.flag, self.held) =
      (state, method, target, flag, held)
  }
}

/// A queue, in order, and the targets `slow_path` answers slow for. N is the propagation node.
struct HeldLayout: CustomTestStringConvertible {
  let name: String
  let slow: Set<Target>
  let queue: [Queued]

  init(_ name: String, slow: Set<Target>, _ queue: [Queued]) {
    (self.name, self.slow, self.queue) = (name, slow, queue)
  }

  var testDescription: String { name }
}

/// `slow_path_held`, from LXMF 1.2.1 (`LXMRouter.py:1834-1853`).
let heldLayouts: [HeldLayout] = [
  HeldLayout(
    "two to one slow target", slow: [.a],
    [Queued(.outbound, .direct, .a, false, false), Queued(.outbound, .direct, .a, false, true)]),
  HeldLayout(
    "in flight direct holds another target", slow: [.a, .b],
    [Queued(.sending, .direct, .a, true, false), Queued(.outbound, .direct, .b, false, true)]),
  HeldLayout(
    "in flight opportunistic is SENT", slow: [.a, .b],
    [
      Queued(.sent, .opportunistic, .a, true, false),
      Queued(.outbound, .opportunistic, .b, false, true),
    ]),
  HeldLayout(
    "SENT direct is not in flight", slow: [.a, .b],
    [Queued(.sent, .direct, .a, true, false), Queued(.outbound, .direct, .b, false, false)]),
  HeldLayout(
    "SENDING opportunistic is not in flight", slow: [.a, .b],
    [
      Queued(.sending, .opportunistic, .a, true, false),
      Queued(.outbound, .opportunistic, .b, false, false),
    ]),
  HeldLayout(
    "propagated and SENT is skipped", slow: [.a, .n],
    [Queued(.sent, .propagated, .a, true, false), Queued(.outbound, .direct, .a, false, false)]),
  HeldLayout(
    "terminal states are skipped", slow: [.a],
    [
      Queued(.delivered, .direct, .a, true, false), Queued(.failed, .direct, .a, true, false),
      Queued(.cancelled, .direct, .a, true, false), Queued(.rejected, .direct, .a, true, false),
      Queued(.outbound, .direct, .a, false, false),
    ]),
  HeldLayout(
    "fast target is never held", slow: [],
    [Queued(.sending, .direct, .a, true, false), Queued(.outbound, .direct, .a, false, false)]),
  HeldLayout(
    "only the candidate's target counts", slow: [.b],
    [Queued(.sending, .direct, .a, true, false), Queued(.outbound, .direct, .b, false, true)]),
  HeldLayout(
    "a candidate that is not OUTBOUND waits for nothing", slow: [.a],
    [Queued(.sending, .direct, .a, true, false), Queued(.sending, .direct, .a, true, false)]),
  HeldLayout(
    "ahead with the same target holds without a flag", slow: [.a],
    [
      Queued(.sent, .opportunistic, .a, false, false),
      Queued(.outbound, .opportunistic, .a, false, true),
    ]),
  HeldLayout(
    "later messages with the same target wait for the first", slow: [.a],
    [
      Queued(.outbound, .direct, .a, false, false), Queued(.outbound, .direct, .a, false, true),
      Queued(.outbound, .direct, .a, false, true),
    ]),
  HeldLayout(
    "behind and in flight holds", slow: [.a],
    [Queued(.outbound, .direct, .a, false, true), Queued(.sending, .direct, .b, true, false)]),
  HeldLayout(
    "propagated target is the node", slow: [.n],
    [
      Queued(.outbound, .propagated, .a, false, false),
      Queued(.outbound, .propagated, .b, false, true),
    ]),
  HeldLayout(
    "a propagated message holds a direct one to the node", slow: [.n],
    [
      Queued(.outbound, .propagated, .a, false, false),
      Queued(.outbound, .direct, .n, false, true),
    ]),
]

// MARK: - Harness

extension SingleNode {
  /// A second remote destination, unknown to the transport like the first.
  func otherDestination() throws -> Destination {
    try Destination(
      identity: Identity(), direction: .in, kind: .single, appName: "lxmf",
      aspects: ["delivery"])
  }

  /// Queues a packed message to `destination` without the enqueue-time pass.
  func enqueueMessage(method: LXMessage.Method, to destination: Destination) throws -> LXMessage {
    let message = LXMessage(
      destination: destination, source: sourceDestination, content: "held",
      desiredMethod: method)
    try message.pack()
    message.state = .outbound
    router.testInjectPendingOutbound(message)
    return message
  }

  /// Queues a delivered message that only an outbound pass dequeues, and returns a semaphore
  /// that pass signals. The router's first jobs tick is 4 s away.
  func passMarker() -> DispatchSemaphore {
    let pass = DispatchSemaphore(value: 0)
    let marker = LXMessage(
      destination: remoteDestination, source: sourceDestination, content: "marker")
    marker.state = .delivered
    marker.onDelivery = { _ in pass.signal() }
    router.testInjectPendingOutbound(marker)
    return pass
  }
}

extension AnnouncedPair {
  /// The hash a message sent by `method` is held against.
  func target(for method: LXMessage.Method) -> Data {
    method == .propagated ? propagationNode : destination.hash
  }

  /// A stand-in propagation node hash. The link the router uses goes to `destination`.
  var propagationNode: Data { Data(repeating: 0xAB, count: 16) }

  /// Gives the router an active link to `destination` for `method`, whose far end accepts
  /// every resource.
  func useActiveLink(for method: LXMessage.Method) throws {
    let link = try Link.initiate(destination: destination, transport: transportA)
    try waitUntil { link.status == .active }
    let linkID = try #require(link.linkID)
    transportB.links[linkID]?.resourceStrategy = .acceptAll
    if method == .propagated {
      router.outboundPropagationNode = propagationNode
      router.outboundPropagationLink = link
    } else {
      router.injectDirectLink(link, for: destination.hash)
    }
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

private struct TimedOut: Error {}

/// Runs the current run loop until `condition` holds, or throws after `timeout` seconds.
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() {
    guard Date() < deadline else { throw TimedOut() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  }
}
