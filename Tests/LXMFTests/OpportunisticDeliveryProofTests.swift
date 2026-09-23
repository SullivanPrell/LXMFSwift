//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXMFSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import LXMF
import ReticulumSwift
import XCTest

/// A receiver proves an opportunistic delivery, so the sender can mark it delivered.
///
/// The reference's `LXMRouter.delivery_packet` calls `packet.prove()` before it parses anything
/// (`LXMRouter.py:1926-1927`), and the sender only reaches DELIVERED when that proof validates
/// against the receipt its send returned (`LXMessage.py`,
/// `set_delivery_callback(__mark_delivered)`).
/// The delivery destination keeps the default `PROVE_NONE` strategy, so the router's call is the
/// only thing that proves an opportunistic packet.
///
/// The sender here is built the way the reference builds one (`LXMessage.__as_packet` then
/// `Packet.send`), not through this port's router, so the assertion depends on the receiver
/// alone.
final class OpportunisticDeliveryProofTests: XCTestCase {

  func testAnOpportunisticDeliveryIsProvedBackToTheSender() throws {
    let net = try OpportunisticPair()

    let received = expectation(description: "receiver parsed the message")
    net.receiverRouter.onMessageReceived = { _ in received.fulfill() }

    let receipt = try XCTUnwrap(
      try net.sendOpportunistically(content: "prove me"),
      "a SINGLE data packet must produce a receipt")

    // Arrival first, so a failure below is about the proof and not about delivery.
    wait(for: [received], timeout: 2.0)

    let proved = expectation(description: "sender's receipt validated")
    poll(until: { receipt.status == .delivered }, fulfilling: proved)
    wait(for: [proved], timeout: 2.0)
  }

  /// The reference proves before it tries to parse (`LXMRouter.py:1927` precedes the `try`), so
  /// a payload that decrypts but is not a valid LXMF message is still acknowledged at the
  /// transport layer.
  func testTheProofIsSentBeforeTheMessageIsParsed() throws {
    let net = try OpportunisticPair()

    let ciphertext = try net.receiverIdentity.encrypt(Data("not an lxmf message".utf8))
    let packet = Packet(
      destinationType: .single, packetType: .data,
      destinationHash: net.receiverDeliveryHash, data: ciphertext)
    let receipt = try XCTUnwrap(try net.senderTransport.send(packet))

    let proved = expectation(description: "sender's receipt validated")
    poll(until: { receipt.status == .delivered }, fulfilling: proved)
    wait(for: [proved], timeout: 2.0)
  }

  private func poll(until condition: @escaping () -> Bool, fulfilling e: XCTestExpectation) {
    DispatchQueue.global().async {
      for _ in 0..<200 {
        if condition() {
          e.fulfill()
          return
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
  }
}

// MARK: - Test network

/// Two transports on a lossless loopback, with an LXMF router on the receiving side only.
private final class OpportunisticPair {
  let senderTransport = Transport()
  let receiverTransport = Transport()
  let senderInterface = Loopback(name: "sender")
  let receiverInterface = Loopback(name: "receiver")

  let senderIdentity = Identity()
  let receiverIdentity = Identity()
  let receiverRouter: LXMRouter
  let receiverDeliveryHash: Data

  init() throws {
    senderInterface.paired = receiverInterface
    receiverInterface.paired = senderInterface
    senderTransport.register(interface: senderInterface)
    receiverTransport.register(interface: receiverInterface)

    receiverRouter = LXMRouter(transport: receiverTransport)
    let delivery = try receiverRouter.register(
      identity: receiverIdentity, transport: receiverTransport)
    receiverDeliveryHash = delivery.hash

    // The sender has already seen the receiver's announce.
    senderTransport.restore(identity: receiverIdentity, forDestination: delivery.hash)
  }

  /// Send one message the way the reference's `LXMessage.send` does for OPPORTUNISTIC, and
  /// return the receipt that send produced.
  func sendOpportunistically(content: String) throws -> PacketReceipt? {
    let destination = try Destination(
      identity: receiverIdentity, direction: .out, kind: .single,
      appName: "lxmf", aspects: ["delivery"])
    let source = try Destination(
      identity: senderIdentity, direction: .in, kind: .single,
      appName: "lxmf", aspects: ["delivery"])
    let message = LXMessage(
      destination: destination, source: source,
      content: Data(content.utf8), desiredMethod: .opportunistic)
    try message.pack()
    let packed = try XCTUnwrap(message.packed)

    // `__as_packet`: the destination hash rides in the header, not the body.
    let body = packed.dropFirst(LXMessage.destinationLength)
    let packet = Packet(
      destinationType: .single, packetType: .data,
      destinationHash: receiverDeliveryHash,
      data: try receiverIdentity.encrypt(Data(body)))
    return try senderTransport.send(packet)
  }
}

private final class Loopback: Interface {
  let name: String
  var bitrate: Int = 1_000_000
  var isOnline: Bool = true
  var inboundHandler: ((Packet, any Interface) -> Void)?
  weak var paired: Loopback?

  init(name: String) { self.name = name }

  func send(_ packet: Packet) throws {
    guard let copy = try? Packet.unpack(try packet.pack()), let paired else { return }
    paired.inboundHandler?(copy, paired)
  }

  func start() throws {}
  func stop() {}
}
