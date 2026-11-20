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

/// LXMF 1.3.1 accepts a stamp over the non-expanded workblock before trying the expanded one
/// (`LXMessage.py:295-301`, `LXStamper.py:27-30`, `:44-49`), and takes a delivery
/// destination's stamp value at registration (`LXMRouter.py:413-422`).
final class LXMF131Tests: XCTestCase {

  /// High enough that a stamp over the bare material passing the expanded check by chance
  /// is a one-in-16384 event.
  private let cost = 14.0

  private func neStamp(_ material: Data) throws -> Data {
    try XCTUnwrap(
      Stamps.generateStamp(material, stampCost: cost, expandRounds: 0, size: LXStamper.stampSize)
    ).stamp
  }

  func testAMessageStampOverTheBareMessageIDIsValid() throws {
    let src = try Destination(
      identity: Identity(), direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
    let dst = try Destination(
      identity: Identity(), direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
    let message = LXMessage(
      destination: dst, source: src, content: "ne", stampCost: cost, stampExpandRounds: 0)
    message.deferStamp = false
    try message.pack()

    let wire = try LXMessage.unpack(try XCTUnwrap(message.packed))

    XCTAssertTrue(wire.validateStamp(targetCost: cost))
    let id = try XCTUnwrap(wire.hash)
    let stamp = try XCTUnwrap(wire.stamp)
    XCTAssertEqual(wire.stampValue, LXStamper.stampValue(workblock: id, stamp: stamp))
  }

  func testAPeeringKeyOverTheBarePeeringIDIsValid() throws {
    let peeringID = Data(repeating: 0x21, count: 32)
    XCTAssertTrue(
      LXStamper.validatePeeringKey(
        peeringID: peeringID, peeringKey: try neStamp(peeringID), targetCost: cost))
  }

  func testAPropagationStampOverTheBareTransientIDIsValid() throws {
    let lxmfData = Data(repeating: 0x5C, count: LXMessage.lxmfOverhead + 40)
    let transientID = Hashes.fullHash(lxmfData)
    let stamp = try neStamp(transientID)

    let result = try XCTUnwrap(
      LXStamper.validatePNStamp(transientData: lxmfData + stamp, targetCost: cost))

    XCTAssertEqual(result.transientID, transientID)
    XCTAssertEqual(result.stamp, stamp)
    XCTAssertEqual(result.stampValue, LXStamper.stampValue(workblock: transientID, stamp: stamp))
  }

  func testRegisteringADeliveryIdentitySetsItsStampValue() throws {
    let transport = Transport()
    let router = LXMRouter(transport: transport)
    let delivery = try router.register(
      identity: Identity(), transport: transport, stampValue: 30)
    XCTAssertEqual(delivery.targetValue(transport.stamps), 30)

    let plain = try LXMRouter(transport: transport).register(
      identity: Identity(), transport: transport)
    XCTAssertEqual(plain.targetValue(transport.stamps), transport.stamps.destinationValue)
  }
}
