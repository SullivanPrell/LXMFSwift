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

/// The outbound retry loop against the reference's numbers and gate—`bugs/013 §9`.
///
/// Three constants and one comparison decide how fast a message converges on a destination
/// the sender has no path to. The reference (LXMF 1.2.0, `LXMRouter.py:32-38`):
///
///     MAX_DELIVERY_ATTEMPTS = 5
///     DELIVERY_RETRY_WAIT   = 10
///     PATH_REQUEST_WAIT     = 7
///     MAX_PATHLESS_TRIES    = 1
///
/// and the opportunistic gate is `delivery_attempts <= attempt_limit` (`LXMRouter.py:2806`), so
/// an opportunistic message is tried six times before `fail_message`. The port shipped `2 / 12 / 15`
/// (the middle one is LXMF's pre-0.2.8 value) and fails fast on `>=`—every number an
/// interop partner would time is different, and delivery to a pathless destination converges
/// roughly twice as slowly as the reference's.
///
/// Every test here drives `processOutbound()` pass by pass, resetting `nextDeliveryAttempt`
/// between passes: the waits themselves are asserted from the timestamps the router writes,
/// never waited out on a clock.
final class OutboundRetryParityTests: XCTestCase {

  // MARK: - The constants are the reference's

  func testRetryConstantsMatchPythonReference() {
    // LXMRouter.py:32-38, LXMF 1.2.0.
    XCTAssertEqual(
      LXMRouter.maxDeliveryAttempts, 5,
      "MAX_DELIVERY_ATTEMPTS (LXMRouter.py:32)")
    XCTAssertEqual(
      LXMRouter.deliveryRetryWait, 10,
      "DELIVERY_RETRY_WAIT (LXMRouter.py:34) — 12 is LXMF's pre-0.2.8 value")
    XCTAssertEqual(
      LXMRouter.pathRequestWait, 7,
      "PATH_REQUEST_WAIT (LXMRouter.py:35)")
    XCTAssertEqual(
      LXMRouter.maxPathlessTries, 1,
      "MAX_PATHLESS_TRIES (LXMRouter.py:38)")
  }

  // MARK: - Pathless opportunistic pacing

  /// One pathless try, then the path request—with the reference's waits on each side.
  /// `LXMRouter.py:2811-2817` (path request after MAX_PATHLESS_TRIES) and `:2835-2838`
  /// (retry spacing of the try itself).
  func testOnePathlessTryThenPathRequestWithReferenceWaits() throws {
    let net = try SingleNode()
    let msg = try net.enqueueMessage(method: .opportunistic)

    // Pass 1: the single pathless try. No path request yet.
    let before1 = Date().timeIntervalSince1970
    net.router.processOutbound()
    XCTAssertEqual(msg.deliveryAttempts, 1)
    XCTAssertTrue(
      net.iface.sentPathRequests().isEmpty,
      "a path request before MAX_PATHLESS_TRIES tries is premature")
    XCTAssertEqual(
      msg.nextDeliveryAttempt - before1, 10, accuracy: 0.5,
      "a failed try is spaced by DELIVERY_RETRY_WAIT = 10 (LXMRouter.py:34,:2838)")

    // Pass 2: attempts == MAX_PATHLESS_TRIES and still no path—request one.
    msg.nextDeliveryAttempt = 0
    let before2 = Date().timeIntervalSince1970
    net.router.processOutbound()
    XCTAssertEqual(
      net.iface.sentPathRequests().count, 1,
      "after MAX_PATHLESS_TRIES = 1 pathless tries the router requests a path "
        + "(LXMRouter.py:2811-2815)")
    XCTAssertEqual(msg.deliveryAttempts, 2)
    XCTAssertEqual(
      msg.nextDeliveryAttempt - before2, 7, accuracy: 0.5,
      "a path request is waited out for PATH_REQUEST_WAIT = 7 (LXMRouter.py:35,:2816)")
  }

  // MARK: - The <= gate: six real attempts, then fail_message

  /// `LXMRouter.py:2806` gates with `<=`, so attempts run 1...6 before `fail_message`
  /// (`:2844-2846`).
  ///
  /// Failing fast on `>=` grants five.
  func testOpportunisticMessageGetsSixAttemptsBeforeFailing() throws {
    let net = try SingleNode()
    let msg = try net.enqueueMessage(method: .opportunistic)
    var failedCallbackFired = false
    msg.onFailed = { _ in failedCallbackFired = true }

    var passes = 0
    while msg.state != .failed && passes < 20 {
      msg.nextDeliveryAttempt = 0
      net.router.processOutbound()
      passes += 1
    }

    XCTAssertEqual(
      msg.state, .failed,
      "a pathless opportunistic message must eventually fail, not retry forever")
    XCTAssertEqual(
      msg.deliveryAttempts, 6,
      "the <= gate (LXMRouter.py:2806) allows MAX_DELIVERY_ATTEMPTS + 1 = 6 attempts")
    XCTAssertTrue(
      failedCallbackFired,
      "fail_message fires the failed callback (LXMRouter.py:2646)")
    XCTAssertFalse(
      net.router.pendingOutbound.contains { $0 === msg },
      "fail_message removes the message from pending_outbound (LXMRouter.py:2644)")
  }

  /// The direct branch counts an attempt before it checks the limit with `<`
  /// (`LXMRouter.py:2911-2915`), so a pathless direct message fails on its fifth attempt
  /// (`:2927-2929`).
  func testDirectMessageFailsOnItsFifthAttempt() throws {
    let net = try SingleNode()
    let msg = try net.enqueueMessage(method: .direct)
    var failedCallbackFired = false
    msg.onFailed = { _ in failedCallbackFired = true }

    var passes = 0
    while msg.state != .failed && passes < 20 {
      msg.nextDeliveryAttempt = 0
      net.router.processOutbound()
      passes += 1
    }

    XCTAssertEqual(msg.state, .failed)
    XCTAssertEqual(
      msg.deliveryAttempts, 5,
      "the attempt is counted, then checked with < (LXMRouter.py:2911-2915)")
    XCTAssertTrue(failedCallbackFired)
    XCTAssertFalse(
      net.router.pendingOutbound.contains { $0 === msg },
      "fail_message removes the message from pending_outbound (LXMRouter.py:2644)")
  }

  // MARK: - Stale-path rediscovery

  /// A path that carried an attempt and keeps failing to deliver is stale: at
  /// `delivery_attempts == MAX_PATHLESS_TRIES + 1` the reference drops it and re-requests
  /// half a second later (`LXMRouter.py:2818-2834`, `rediscover_job`), instead of retrying
  /// into the dead path until the message fails.
  ///
  /// This is the only branch that can recover
  /// a message whose path entry outlived the route.
  func testStalePathIsDroppedAndRediscovered() throws {
    // Two transports on a synchronous wire: B announces a delivery destination, so A
    // holds a real path table entry and can recall B's identity—a path that *looks*
    // healthy, which is exactly what a stale entry looks like.
    let transportA = Transport()
    let transportB = Transport()
    let ifaceA = PeerSyncLoopInterface(name: "a")
    let ifaceB = PeerSyncLoopInterface(name: "b")
    ifaceA.paired = ifaceB
    ifaceB.paired = ifaceA
    transportA.register(interface: ifaceA)
    transportB.register(interface: ifaceB)

    let identityB = Identity()
    let destB = try Destination(
      identity: identityB, direction: .in, kind: .single,
      appName: "lxmf", aspects: ["delivery"])
    transportB.ownerIdentity = identityB
    transportB.register(destination: destB)
    _ = try transportB.announce(destination: destB)

    let pathLearned = Date().addingTimeInterval(2.0)
    while !transportA.hasPath(to: destB.hash) && Date() < pathLearned {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertTrue(
      transportA.hasPath(to: destB.hash),
      "precondition: the announce must have given A a path to B")

    let router = LXMRouter(transport: transportA)
    let sourceIdentity = Identity()
    let sourceDestination = try Destination(
      identity: sourceIdentity, direction: .in, kind: .single,
      appName: "lxmf", aspects: ["delivery"])
    let msg = LXMessage(
      destination: destB, source: sourceDestination,
      content: "stale path", desiredMethod: .opportunistic)
    try msg.pack()
    msg.state = .outbound
    msg.deliveryAttempts = LXMRouter.maxPathlessTries + 1
    // The previous attempt went out on this path (`LXMRouter.py:2818`).
    msg.sentOnPath = true
    router.testInjectPendingOutbound(msg)

    ifaceA.clearSent()
    let before = Date().timeIntervalSince1970
    router.processOutbound()

    XCTAssertFalse(
      transportA.hasPath(to: destB.hash),
      "the stale path is dropped (LXMRouter.py:2828)")
    XCTAssertTrue(
      ifaceA.sent.filter { $0.destinationHash == destB.hash }.isEmpty,
      "the rediscovery pass must not send into the path it just judged stale")
    XCTAssertEqual(
      msg.deliveryAttempts, LXMRouter.maxPathlessTries + 2,
      "the rediscovery counts as an attempt (LXMRouter.py:2820)")
    XCTAssertEqual(
      msg.nextDeliveryAttempt - before, LXMRouter.pathRequestWait, accuracy: 0.5,
      "the rediscovery is waited out for PATH_REQUEST_WAIT (LXMRouter.py:2833)")

    // The re-request runs 0.5 s after the drop (LXMRouter.py:2829-2832).
    let requested = Date().addingTimeInterval(2.5)
    while ifaceA.sentPathRequests().isEmpty && Date() < requested {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertEqual(
      ifaceA.sentPathRequests().count, 1,
      "the dropped path is re-requested (LXMRouter.py:2831)")
  }
}

// MARK: - Harness

/// One router on one transport with a recording interface and a destination that is
/// deliberately unknown: no announce is ever processed, so `recall` fails and no path
/// exists—the exact situation the pathless retry ladder exists for.
final class SingleNode {
  let transport = Transport()
  let iface = PeerSyncLoopInterface(name: "recording")
  let router: LXMRouter

  let sourceIdentity = Identity()
  let destinationIdentity = Identity()
  let sourceDestination: Destination
  let remoteDestination: Destination

  init() throws {
    transport.register(interface: iface)
    router = LXMRouter(transport: transport)
    sourceDestination = try Destination(
      identity: sourceIdentity, direction: .in, kind: .single,
      appName: "lxmf", aspects: ["delivery"])
    remoteDestination = try Destination(
      identity: destinationIdentity, direction: .in, kind: .single,
      appName: "lxmf", aspects: ["delivery"])
  }

  /// Pack a small message and place it in the outbound queue without triggering the
  /// enqueue-time delivery pass, so each test drives `processOutbound()` explicitly.
  func enqueueMessage(method: LXMessage.Method) throws -> LXMessage {
    let msg = LXMessage(
      destination: remoteDestination,
      source: sourceDestination,
      content: "retry parity",
      desiredMethod: method)
    try msg.pack()
    msg.state = .outbound
    router.testInjectPendingOutbound(msg)
    return msg
  }
}
