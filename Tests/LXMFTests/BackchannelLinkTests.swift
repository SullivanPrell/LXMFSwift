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

/// Backchannel links, against LXMF 1.2.0 (`LXMRouter.py:114`, `:769-771`, `:2064-2067`,
/// `:2770-2783`, `:2856-2902`).
///
/// A sender that delivers a DIRECT message identifies on its link as its own delivery identity,
/// once. The receiver files that link under the sender's delivery hash and sends to the sender
/// over it instead of opening a link back. Expected values are `PythonBackchannelVectors`.
@Suite("Backchannel links")
struct BackchannelLinkTests {

  private typealias Vectors = PythonBackchannelVectors

  // MARK: - Identification

  @Test("A delivered direct message identifies the sender as its delivery identity, once")
  func senderIdentifiesOnceAfterDelivery() throws {
    let pair = try BackchannelPair()

    let first = try pair.sendAToB("first")
    #expect(first.state == .delivered)
    #expect(pair.identifications(sentBy: pair.ifaceA) == Vectors.identificationsAfterFirstDelivery)
    let inbound = try #require(pair.inboundLinkAtB())
    #expect(inbound.remoteIdentity?.publicKeyBytes.hexString == Vectors.identityAPublicKey)

    let second = try pair.sendAToB("second")
    #expect(second.state == .delivered)
    #expect(
      pair.identifications(sentBy: pair.ifaceA) == Vectors.identificationsAfterSecondDelivery)
  }

  @Test("A direct message delivered as a resource identifies the sender too")
  func senderIdentifiesAfterResourceDelivery() throws {
    let pair = try BackchannelPair()

    let message = try pair.sendAToB(String(repeating: "x", count: 2000))
    #expect(message.representation == .resource)
    try pair.waitUntil { message.state == .delivered }

    #expect(
      pair.identifications(sentBy: pair.ifaceA) == Vectors.identificationsAfterResourceDelivery)
    #expect(
      pair.routerB.deliveryLinkAvailable(destinationHash: pair.hashA)
        == Vectors.availableForIdentifiedRemote)
  }

  @Test("A sender doesn't identify on a link it didn't initiate")
  func noIdentificationOnResponderLink() throws {
    let pair = try BackchannelPair()
    _ = try pair.sendAToB("hello")
    let inbound = try #require(pair.inboundLinkAtB())
    pair.routerB.injectDirectLink(inbound, for: pair.hashA)
    pair.ifaceB.clearSent()

    let message = try pair.sendBToA("over the responder link")

    #expect(message.state == .delivered)
    #expect(pair.identifications(sentBy: pair.ifaceB) == Vectors.identificationsOnResponderLink)
  }

  @Test("A sender doesn't identify as a source it hasn't registered for delivery")
  func noIdentificationForUnregisteredSource() throws {
    let pair = try BackchannelPair()
    let source = try Destination(
      identity: Identity(privateKeyBytes: Vectors.identityCPrivateKey), direction: .in,
      kind: .single, appName: "lxmf", aspects: ["delivery"])

    let message = try pair.sendAToB("from an unregistered source", source: source)

    #expect(message.state == .delivered)
    #expect(
      pair.identifications(sentBy: pair.ifaceA) == Vectors.identificationsForUnregisteredSource)
    #expect(
      pair.routerB.deliveryLinkAvailable(destinationHash: pair.hashA) == Vectors.availableForUnknown
    )
  }

  @Test("An opportunistic delivery doesn't identify on a direct link to the same destination")
  func noIdentificationForOpportunistic() throws {
    let pair = try BackchannelPair()
    let link = try Link.initiate(destination: pair.outboundB(), transport: pair.transportA)
    try pair.waitUntil { link.status == .active }
    pair.routerA.injectDirectLink(link, for: pair.hashB)

    let message = try pair.sendAToB("opportunistic", method: .opportunistic)
    try pair.waitUntil { message.state == .delivered }

    #expect(pair.identifications(sentBy: pair.ifaceA) == Vectors.identificationsForOpportunistic)
  }

  // MARK: - Availability

  @Test("A delivery link is available over a direct link or a backchannel, and not otherwise")
  func deliveryLinkAvailability() throws {
    let pair = try BackchannelPair()
    #expect(
      pair.routerB.deliveryLinkAvailable(destinationHash: pair.hashA) == Vectors.availableForUnknown
    )

    _ = try pair.sendAToB("hello")

    #expect(pair.hashA.hexString == Vectors.deliveryHashA)
    #expect(
      pair.routerB.deliveryLinkAvailable(destinationHash: pair.hashA)
        == Vectors.availableForIdentifiedRemote)
    #expect(
      pair.routerA.deliveryLinkAvailable(destinationHash: pair.hashB)
        == Vectors.availableForDirectLinkOnly)
    #expect(
      pair.routerB.deliveryLinkAvailable(destinationHash: Data(repeating: 0, count: 16))
        == Vectors.availableForUnknown)
  }

  // MARK: - Sending over a backchannel

  @Test("The receiver sends to the sender over the backchannel instead of opening a link")
  func sendReusesInboundLink() throws {
    let pair = try BackchannelPair()
    _ = try pair.sendAToB("hello")
    let inbound = try #require(pair.inboundLinkAtB())
    let inboundID = try #require(inbound.linkID)
    pair.ifaceB.clearSent()

    let reply = try pair.sendBToA("reply")

    #expect(reply.state == .delivered)
    #expect(pair.receivedByA.map(\.contentAsString) == ["reply"])
    #expect(reply.deliveryAttempts == Vectors.backchannelSendAttempts)
    #expect(pair.routerB.directLinks[pair.hashA] == nil)
    #expect(pair.linkRequests(sentBy: pair.ifaceB) == Vectors.backchannelSendLinksConstructed)
    #expect(pair.dataPackets(sentBy: pair.ifaceB, on: inboundID) == 1)
    #expect(pair.identifications(sentBy: pair.ifaceB) == Vectors.identificationsOverBackchannel)
  }

  @Test("A large message over the backchannel arrives as a resource")
  func largeMessageOverBackchannel() throws {
    let pair = try BackchannelPair()
    _ = try pair.sendAToB("hello")
    let content = String(repeating: "y", count: 2000)

    let reply = try pair.sendBToA(content)
    #expect(reply.representation == .resource)
    try pair.waitUntil { reply.state == .delivered }

    #expect(pair.receivedByA.map(\.contentAsString) == [content])
    #expect(pair.linkRequests(sentBy: pair.ifaceB) == Vectors.backchannelSendLinksConstructed)
  }

  @Test("A direct link is preferred over the backchannel")
  func directLinkPreferred() throws {
    let pair = try BackchannelPair()
    _ = try pair.sendAToB("hello")
    let link = try Link.initiate(destination: pair.outboundA(), transport: pair.transportB)
    try pair.waitUntil { link.status == .active }
    pair.routerB.injectDirectLink(link, for: pair.hashA)
    let directID = try #require(link.linkID)
    let inboundID = try #require(pair.inboundLinkAtB()?.linkID)
    pair.ifaceB.clearSent()

    let reply = try pair.sendBToA("over the direct link")

    #expect(reply.state == .delivered)
    let used = pair.dataPackets(sentBy: pair.ifaceB, on: directID) == 1 ? "direct" : "backchannel"
    #expect(used == Vectors.preferredLink)
    #expect(pair.dataPackets(sentBy: pair.ifaceB, on: inboundID) == 0)
  }

  @Test("A closed backchannel is dropped and its path requested again")
  func closedBackchannelDropped() throws {
    let pair = try BackchannelPair()
    _ = try pair.sendAToB("hello")
    let outbound = try #require(pair.routerA.directLinks[pair.hashB])
    let inbound = try #require(pair.inboundLinkAtB())
    try outbound.teardown()
    #expect(inbound.status == .closed)
    #expect(
      pair.routerB.deliveryLinkAvailable(destinationHash: pair.hashA)
        == Vectors.closedAvailableBefore)
    pair.ifaceB.clearSent()
    let before = Date().timeIntervalSince1970

    let reply = try pair.sendBToA("after close")

    #expect(
      pair.routerB.deliveryLinkAvailable(destinationHash: pair.hashA)
        == Vectors.closedAvailableAfter)
    #expect(pair.ifaceB.sentPathRequests().count == Vectors.closedPathRequests)
    #expect(reply.deliveryAttempts == Vectors.closedAttempts)
    #expect((reply.nextDeliveryAttempt > before) == Vectors.closedRescheduled)
  }
}

// MARK: - Harness

/// Two routers on a synchronous loopback, holding the identities `PythonBackchannelVectors` uses.
///
/// B announces, so A has a path to B. B knows A's identity but holds no path to A, so B can only
/// reach A over a link A opened.
final class BackchannelPair {
  let transportA = Transport()
  let transportB = Transport()
  let ifaceA = PeerSyncLoopInterface(name: "a")
  let ifaceB = PeerSyncLoopInterface(name: "b")
  let identityA: Identity
  let identityB: Identity
  let routerA: LXMRouter
  let routerB: LXMRouter
  let deliveryA: Destination
  let deliveryB: Destination

  private let lock = NSLock()
  private var unsafeReceivedByA: [LXMessage] = []

  var hashA: Data { deliveryA.hash }
  var hashB: Data { deliveryB.hash }

  /// Messages A's router delivered to the application.
  var receivedByA: [LXMessage] {
    lock.lock()
    defer { lock.unlock() }
    return unsafeReceivedByA
  }

  init() throws {
    ifaceA.paired = ifaceB
    ifaceB.paired = ifaceA
    transportA.register(interface: ifaceA)
    transportB.register(interface: ifaceB)

    identityA = try Identity(privateKeyBytes: PythonBackchannelVectors.identityAPrivateKey)
    identityB = try Identity(privateKeyBytes: PythonBackchannelVectors.identityBPrivateKey)
    routerA = LXMRouter(transport: transportA)
    routerB = LXMRouter(transport: transportB)
    deliveryA = try routerA.register(identity: identityA, transport: transportA)
    deliveryB = try routerB.register(identity: identityB, transport: transportB)

    transportB.ownerIdentity = identityB
    _ = try transportB.announce(destination: deliveryB)
    let deadline = Date().addingTimeInterval(2)
    while !transportA.hasPath(to: deliveryB.hash) && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    guard transportA.hasPath(to: deliveryB.hash) else { throw PairError.noPath }
    transportB.restore(identity: identityA, forDestination: deliveryA.hash)

    routerA.onMessageReceived = { [weak self] message in
      guard let self else { return }
      lock.lock()
      unsafeReceivedByA.append(message)
      lock.unlock()
    }
  }

  func outboundA() throws -> Destination {
    try Destination(
      identity: identityA, direction: .out, kind: .single, appName: "lxmf", aspects: ["delivery"])
  }

  func outboundB() throws -> Destination {
    try Destination(
      identity: identityB, direction: .out, kind: .single, appName: "lxmf", aspects: ["delivery"])
  }

  /// Sends from A to B through A's router.
  func sendAToB(
    _ content: String, source: Destination? = nil, method: LXMessage.Method = .direct
  ) throws -> LXMessage {
    let message = LXMessage(
      destination: try outboundB(), source: source ?? deliveryA, content: content,
      desiredMethod: method)
    try routerA.send(message)
    return message
  }

  /// Sends from B to A through B's router.
  func sendBToA(_ content: String) throws -> LXMessage {
    let message = LXMessage(
      destination: try outboundA(), source: deliveryB, content: content, desiredMethod: .direct)
    try routerB.send(message)
    return message
  }

  /// B's end of the link A opened for delivery.
  func inboundLinkAtB() -> Link? {
    guard let id = routerA.directLinks[hashB]?.linkID else { return nil }
    return transportB.links[id]
  }

  /// LINKIDENTIFY packets an interface sent.
  func identifications(sentBy iface: PeerSyncLoopInterface) -> Int {
    iface.sent.filter { $0.context == .linkIdentify }.count
  }

  /// Link requests an interface sent.
  func linkRequests(sentBy iface: PeerSyncLoopInterface) -> Int {
    iface.sent.filter { $0.packetType == .linkRequest }.count
  }

  /// Plain data packets an interface sent on a link.
  func dataPackets(sentBy iface: PeerSyncLoopInterface, on linkID: Data) -> Int {
    iface.sent.filter {
      $0.destinationHash == linkID && $0.packetType == .data && $0.context == .none
    }.count
  }

  /// Runs the current run loop until `condition` holds, or throws after `timeout` seconds.
  func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { throw PairError.timedOut }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
  }

  enum PairError: Error { case noPath, timedOut }
}
