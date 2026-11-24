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

/// A propagation node that is also someone's LXMF address delivers their messages.
///
/// `lxmf_propagation` decrypts a message for one of its own delivery destinations and hands it
/// to `lxmf_delivery` instead of storing it (`LXMRouter.py:2858-2868`).
final class PropagationLocalDeliveryTests: XCTestCase {

  private var tempDir: String!

  override func setUp() {
    super.setUp()
    tempDir = NSTemporaryDirectory() + "lxmf_pnlocal_\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: tempDir)
    super.tearDown()
  }

  /// The propagated bytes of a message: destination hash and the encrypted rest.
  private func propagatedBytes(to recipient: Identity, content: String) throws -> Data {
    let source = try Destination(
      identity: Identity(), direction: .in, kind: .single, appName: appName,
      aspects: ["delivery"])
    let destination = try Destination(
      identity: Identity(publicKeyBytes: recipient.publicKeyBytes), direction: .out, kind: .single,
      appName: appName, aspects: ["delivery"])
    let message = LXMessage(
      destination: destination, source: source, content: content, desiredMethod: .propagated)
    try message.pack()
    guard case .array(let outer) = try MsgPack.decode(XCTUnwrap(message.propagationPacked)),
      case .array(let entries) = outer[1], case .bytes(let lxmfData) = entries[0]
    else { throw XCTSkip("unexpected propagation container") }
    return lxmfData
  }

  func testAMessageForTheNodesOwnAddressIsDeliveredNotStored() throws {
    let transport = Transport()
    let identity = Identity()
    let router = LXMRouter(transport: transport)
    try router.register(identity: identity, transport: transport)
    try router.enablePropagation(storagePath: tempDir)

    var received: [String] = []
    router.onMessageReceived = { received.append($0.contentAsString ?? "") }

    let local = try propagatedBytes(to: identity, content: "for the operator")
    let stamp = Data(repeating: 0x11, count: LXStamper.stampSize)
    XCTAssertNil(router.ingestPropagatedLXM(lxmfData: local, stampValue: 8, stamp: stamp))
    XCTAssertEqual(received, ["for the operator"])
    XCTAssertTrue(router.propagationEntries.isEmpty, "a locally delivered message isn't stored")
    XCTAssertTrue(router.peerDistributionQueue.isEmpty, "nor offered to peers")

    // Uploaded again, it is a duplicate.
    XCTAssertNil(router.ingestPropagatedLXM(lxmfData: local, stampValue: 8, stamp: stamp))
    XCTAssertEqual(received.count, 1)

    // Reference cell: a message for someone else is stored.
    let other = try propagatedBytes(to: Identity(), content: "for a client")
    XCTAssertNotNil(router.ingestPropagatedLXM(lxmfData: other, stampValue: 8, stamp: stamp))
    XCTAssertEqual(received.count, 1)
  }
}
