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

/// An opportunistic message is reported delivered only when the recipient proves it.
///
/// The reference sends the packet and hangs `__mark_delivered` on its receipt
/// (`LXMessage.py:467-472`); SENT only means the packet left. `process_outbound` removes a
/// message at DELIVERED, or at SENT only for PROPAGATED (`LXMRouter.py:2686-2716`), so an
/// unproved opportunistic message falls through to the opportunistic branch and is sent again
/// every `DELIVERY_RETRY_WAIT` until `MAX_DELIVERY_ATTEMPTS` fails it (`:2732-2761`).
///
/// This port discarded the receipt, set `.sent`, and `processOutbound` treated `.sent` like
/// `.delivered`: the message was dequeued and `onDelivery` fired on the next tick, whether or
/// not anyone received it. `ProofGatedDeliveryTests` closed the same defect for DIRECT
/// (`bugs/014`).
///
/// Every test here separates "received" from "proved": one drops the proof, one holds it.
final class OpportunisticProofGatedDeliveryTests: XCTestCase {

  // MARK: - Received but never proved

  /// A receiver that takes the message and never proves it leaves the message undelivered and
  /// still queued.
  func testAnUnprovedMessageIsNotDeliveredAndStaysQueued() throws {
    let net = try OpportunisticPair()
    net.receiverInterface.dropOutbound = { $0.packetType == .proof }

    let deliveryFired = Flag()
    let message = try net.enqueue(content: "unproved", onDelivery: { _ in deliveryFired.raise() })

    net.senderRouter.processOutbound()
    XCTAssertEqual(net.receivedCount, 1, "precondition: the receiver has the message")
    XCTAssertEqual(message.state, .sent, "SENT means the packet left (LXMessage.py:472)")

    // The pass that used to dequeue `.sent` as delivered.
    net.senderRouter.processOutbound()

    XCTAssertFalse(deliveryFired.isRaised, "no proof came back, so nothing was delivered")
    XCTAssertNotEqual(message.state, .delivered)
    XCTAssertTrue(
      net.senderRouter.pendingOutbound.contains { $0 === message },
      "only DELIVERED dequeues an opportunistic message (LXMRouter.py:2686)")
  }

  /// An unproved message is sent again after `DELIVERY_RETRY_WAIT` and failed after the
  /// reference's attempt ladder: the `<=` gate allows `MAX_DELIVERY_ATTEMPTS + 1` attempts
  /// (`LXMRouter.py:2736`, fail at `:2760-2761`).
  func testAnUnprovedMessageIsRetriedAndThenFailed() throws {
    let net = try OpportunisticPair()
    net.receiverInterface.dropOutbound = { $0.packetType == .proof }

    let deliveryFired = Flag()
    let failedFired = Flag()
    let message = try net.enqueue(content: "retried", onDelivery: { _ in deliveryFired.raise() })
    message.onFailed = { _ in failedFired.raise() }

    let before = Date().timeIntervalSince1970
    net.senderRouter.processOutbound()
    XCTAssertEqual(
      message.nextDeliveryAttempt - before, LXMRouter.deliveryRetryWait, accuracy: 0.5,
      "the next attempt is DELIVERY_RETRY_WAIT away (LXMRouter.py:2756)")

    var passes = 1
    while message.state != .failed && passes < 30 {
      message.nextDeliveryAttempt = 0
      net.senderRouter.processOutbound()
      // The stale-path rediscovery re-requests the path 0.5 s after dropping it.
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      passes += 1
    }

    XCTAssertEqual(net.receivedCount, 1, "precondition: the receiver has the message")
    XCTAssertGreaterThanOrEqual(
      net.messagesSent, 2, "an unproved message is sent again, not dequeued after one send")
    XCTAssertEqual(message.state, .failed, "an unproved message ends failed, not delivered")
    XCTAssertEqual(
      message.deliveryAttempts, LXMRouter.maxDeliveryAttempts + 1,
      "the <= gate allows MAX_DELIVERY_ATTEMPTS + 1 attempts (LXMRouter.py:2736)")
    XCTAssertFalse(deliveryFired.isRaised, "no proof ever came back")
    XCTAssertTrue(failedFired.isRaised, "fail_message fires the failed callback")
    XCTAssertFalse(net.senderRouter.pendingOutbound.contains { $0 === message })
  }

  // MARK: - Proved

  /// Delivery is reported when the proof arrives, not when the message does.
  func testTheProofMarksTheMessageDeliveredAndFiresOnDelivery() throws {
    let net = try OpportunisticPair()
    net.receiverInterface.holdOutbound = { $0.packetType == .proof }

    let deliveryCount = Counter()
    let message = try net.enqueue(content: "proved", onDelivery: { _ in deliveryCount.increment() })

    net.senderRouter.processOutbound()
    net.senderRouter.processOutbound()
    XCTAssertEqual(net.receivedCount, 1, "precondition: the receiver has the message")
    XCTAssertEqual(deliveryCount.value, 0, "the proof is held, so delivery cannot be reported yet")
    XCTAssertNotEqual(message.state, .delivered)

    net.receiverInterface.releaseHeld()
    try net.waitUntil { deliveryCount.value > 0 }

    XCTAssertEqual(message.state, .delivered, "__mark_delivered sets DELIVERED (LXMessage.py:563)")
    XCTAssertEqual(deliveryCount.value, 1, "the delivery callback fires on the proof")
    XCTAssertEqual(message.progress, 1.0, accuracy: 0.0001)
    XCTAssertNotNil(message.deliveryReceipt, "the receipt is kept for the application to read")
    XCTAssertFalse(
      net.senderRouter.pendingOutbound.contains { $0 === message },
      "a delivered message leaves the queue (LXMRouter.py:2688)")

    net.senderRouter.processOutbound()
    XCTAssertEqual(deliveryCount.value, 1, "a later pass does not report delivery a second time")
  }

  /// A proof for an earlier attempt still counts: the reference keeps the callback on every
  /// receipt it created.
  func testAProofForAnEarlierAttemptStillDelivers() throws {
    let net = try OpportunisticPair()
    net.receiverInterface.holdOutbound = { $0.packetType == .proof }

    let deliveryCount = Counter()
    let message = try net.enqueue(content: "late", onDelivery: { _ in deliveryCount.increment() })

    net.senderRouter.processOutbound()
    message.nextDeliveryAttempt = 0
    net.senderRouter.processOutbound()
    XCTAssertEqual(net.messagesSent, 2, "precondition: the message was sent twice")
    XCTAssertEqual(net.receiverInterface.heldCount, 2, "precondition: both sends were proved")

    // Only the first attempt's proof: the receipt the second attempt replaced.
    net.receiverInterface.releaseFirstHeld()
    try net.waitUntil { deliveryCount.value > 0 }
    XCTAssertEqual(message.state, .delivered)

    net.receiverInterface.releaseHeld()
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertEqual(deliveryCount.value, 1, "two proofs report one delivery")
  }
}

// MARK: - Harness

/// Two routers on two transports joined by a loopback that can drop or hold selected packets.
///
/// The receiver's delivery destination proves every packet, so the only thing deciding whether
/// a proof reaches the sender is the interface.
private final class OpportunisticPair {
  let senderTransport = Transport()
  let receiverTransport = Transport()
  let senderInterface = GatedInterface(name: "sender")
  let receiverInterface = GatedInterface(name: "receiver")

  let senderRouter: LXMRouter
  let receiverRouter: LXMRouter
  let senderDestination: Destination
  let receiverDestination: Destination

  private let received = Counter()
  /// Messages the receiver's router handed to the application.
  ///
  /// The router drops a repeat of a message it already has, so retries do not raise this.
  var receivedCount: Int { received.value }
  /// Opportunistic LXMF packets the sender put on the wire, one per attempt.
  var messagesSent: Int {
    senderInterface.sentCount { [receiverDestination] in
      $0.packetType == .data && $0.destinationHash == receiverDestination.hash
    }
  }

  init() throws {
    senderInterface.paired = receiverInterface
    receiverInterface.paired = senderInterface
    senderTransport.register(interface: senderInterface)
    receiverTransport.register(interface: receiverInterface)

    let senderIdentity = Identity()
    let receiverIdentity = Identity()
    receiverTransport.ownerIdentity = receiverIdentity

    senderRouter = LXMRouter(transport: senderTransport)
    receiverRouter = LXMRouter(transport: receiverTransport)
    senderDestination = try senderRouter.register(
      identity: senderIdentity, transport: senderTransport)
    receiverDestination = try receiverRouter.register(
      identity: receiverIdentity, transport: receiverTransport)
    receiverDestination.proofStrategy = .proveAll
    receiverRouter.onMessageReceived = { [received] _ in received.increment() }

    // A real path, so every attempt sends instead of taking the pathless branch.
    _ = try receiverTransport.announce(destination: receiverDestination)
    guard senderTransport.hasPath(to: receiverDestination.hash) else {
      throw HarnessError.noPath
    }
  }

  /// Wait for a receipt callback, which ReticulumSwift runs on a global queue.
  func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2.0) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { throw HarnessError.timedOut }
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  /// Queue one opportunistic message without the enqueue-time pass, so each test drives
  /// `processOutbound()` itself.
  func enqueue(content: String, onDelivery: @escaping (LXMessage) -> Void) throws -> LXMessage {
    let message = LXMessage(
      destination: receiverDestination,
      source: senderDestination,
      content: Data(content.utf8),
      desiredMethod: .opportunistic)
    try message.pack()
    message.state = .outbound
    message.onDelivery = onDelivery
    senderRouter.testInjectPendingOutbound(message)
    return message
  }
}

private enum HarnessError: Error {
  /// The announce did not give the sender a path; every test here would test the pathless
  /// branch instead.
  case noPath
  /// A receipt callback did not arrive.
  case timedOut
}

/// A synchronous loopback interface that can drop packets outright or hold them for later
/// release.
private final class GatedInterface: Interface {
  let name: String
  var bitrate: Int = 1_000_000
  var isOnline: Bool = true
  var inboundHandler: ((Packet, any Interface) -> Void)?
  weak var paired: GatedInterface?

  /// Packets matching this are discarded, as a lossy hop would discard them.
  var dropOutbound: ((Packet) -> Bool)?
  /// Packets matching this are queued until `releaseHeld()`.
  var holdOutbound: ((Packet) -> Bool)?

  private let lock = NSLock()
  private var held: [Data] = []
  private var sent: [Packet] = []

  init(name: String) { self.name = name }

  func sentCount(where predicate: (Packet) -> Bool) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return sent.filter(predicate).count
  }

  func send(_ packet: Packet) throws {
    lock.lock()
    sent.append(packet)
    lock.unlock()
    if dropOutbound?(packet) == true { return }
    let raw = try packet.pack()
    if holdOutbound?(packet) == true {
      lock.lock()
      held.append(raw)
      lock.unlock()
      return
    }
    deliver(raw)
  }

  var heldCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return held.count
  }

  /// Deliver only the oldest held packet.
  func releaseFirstHeld() {
    lock.lock()
    let first = held.isEmpty ? nil : held.removeFirst()
    lock.unlock()
    if let first { deliver(first) }
  }

  func releaseHeld() {
    lock.lock()
    let queued = held
    held = []
    lock.unlock()
    for raw in queued { deliver(raw) }
  }

  private func deliver(_ raw: Data) {
    guard let copy = try? Packet.unpack(raw), let paired else { return }
    paired.inboundHandler?(copy, paired)
  }

  func start() throws {}
  func stop() {}
}

/// Thread-safe boolean.
private final class Flag {
  private let lock = NSLock()
  private var raised = false

  func raise() {
    lock.lock()
    raised = true
    lock.unlock()
  }
  var isRaised: Bool {
    lock.lock()
    defer { lock.unlock() }
    return raised
  }
}

/// Thread-safe counter.
private final class Counter {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
