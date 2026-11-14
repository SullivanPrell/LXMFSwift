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

/// LXMF 1.3.0's fractional stamp costs, checked against `PythonStampCostVectors`.
@Suite("LXMF 1.3.0 stamp costs")
struct StampCostTests {

  typealias V = PythonStampCostVectors

  static func bytes(_ hex: String) -> Data { Data(hex: hex)! }

  static func items(_ appData: Data?) -> [MsgPack.Value] {
    guard let appData, case .array(let items) = try? MsgPack.decode(appData) else { return [] }
    return items
  }

  static func numbers(_ value: MsgPack.Value) -> [Double?] {
    guard case .array(let items) = value else { return [] }
    return items.map(\.asDouble)
  }

  // MARK: - Stamps (LXStamper.py:9-43)

  @Test("stamp values and validity match RNS.Stamps over each LXMF workblock")
  func stampValueAndValidity() {
    let material = Self.bytes(V.material)
    for row in V.stamps {
      let workblock = LXStamper.stampWorkblock(material: material, expandRounds: row.rounds)
      let stamp = Self.bytes(row.stamp)
      #expect(LXStamper.stampValue(workblock: workblock, stamp: stamp) == row.value)
      for check in row.validity {
        #expect(
          LXStamper.stampValid(stamp: stamp, targetCost: check.cost, workblock: workblock)
            == check.valid, "\(row.rounds) rounds at cost \(check.cost)")
      }
    }
  }

  @Test("validate_pn_stamp returns the fractional value, or nothing below the cost")
  func pnStamp() {
    let transientData = Self.bytes(V.pnLXMData) + Self.bytes(V.pnStamp)
    for row in V.pnResults {
      let result = LXStamper.validatePNStamp(transientData: transientData, targetCost: row.cost)
      #expect(result?.stampValue == row.value, "cost \(row.cost)")
    }
  }

  @Test("validate_peering_key takes a fractional cost")
  func peeringKey() {
    for row in V.peeringResults {
      #expect(
        LXStamper.validatePeeringKey(
          peeringID: Self.bytes(V.peeringID), peeringKey: Self.bytes(V.peeringKey),
          targetCost: row.cost) == row.valid, "cost \(row.cost)")
    }
  }

  @Test("a generated stamp reports the fractional value it reached")
  func generatedStampValue() throws {
    let material = Data(repeating: 0x42, count: 32)
    let found = try #require(
      LXStamper.generateStamp(material: material, targetCost: 2.5, expandRounds: 2))
    let workblock = LXStamper.stampWorkblock(material: material, expandRounds: 2)
    #expect(found.value >= 2.5)
    #expect(found.value == LXStamper.stampValue(workblock: workblock, stamp: found.stamp))
  }

  // MARK: - The message store (LXMRouter.py:656, :2869-2877)

  static func propagationRouter() throws -> (LXMRouter, String) {
    let dir = NSTemporaryDirectory() + "lxmf_stampcost_\(UUID().uuidString)"
    let router = LXMRouter(transport: Transport())
    try router.enablePropagation(storagePath: dir)
    return (router, dir)
  }

  static func uniqueBody() -> Data {
    var body = Data(repeating: 0x5A, count: 120)
    body.replaceSubrange(0..<16, with: UUID().uuidString.prefix(16).utf8)
    return body
  }

  @Test("a stored message's file name carries the quantized stamp value")
  func storeFileNameComponent() throws {
    let (router, dir) = try Self.propagationRouter()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    for row in V.storeValueComponents {
      let body = Self.uniqueBody()
      let entry = try #require(
        router.addToMessageStore(
          lxmfData: body, transientID: Hashes.fullHash(body), stampValue: row.value,
          stamp: Data(repeating: 0, count: 32)))
      #expect(entry.filePath.hasSuffix(row.component), "\(entry.filePath)")
      #expect(entry.stampValue == Stamps.quantizeCost(row.value))
    }
  }

  @Test("indexing the store reads each value component through quantize_cost")
  func storeFileNameRead() throws {
    let dir = NSTemporaryDirectory() + "lxmf_stampcost_\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = dir + "/lxmf/messagestore"
    try FileManager.default.createDirectory(atPath: store, withIntermediateDirectories: true)
    var expected: [Data: Double] = [:]
    for row in V.storeValueReads {
      let body = Self.uniqueBody()
      let transientID = Hashes.fullHash(body)
      let name = "\(transientID.hexString)_1700000000.5_\(row.component)"
      try (body + Data(repeating: 0, count: 32)).write(to: URL(fileURLWithPath: store + "/" + name))
      expected[transientID] = row.value
    }

    let router = LXMRouter(transport: Transport())
    try router.enablePropagation(storagePath: dir)

    for (transientID, value) in expected {
      #expect(router.peerEntry(transientID)?.stampValue == value)
    }
  }

  @Test("a propagation node drops a message with no stamp value")
  func ingestWithoutStampValue() throws {
    let (router, dir) = try Self.propagationRouter()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let body = Self.uniqueBody()
    let entry = router.ingestPropagatedLXM(
      lxmfData: body, stampValue: 0, stamp: Data(repeating: 0, count: 32))
    #expect(entry == nil)
    #expect(router.peerEntry(Hashes.fullHash(body)) == nil)
  }

  // MARK: - The delivery announce (LXMRouter.py:444-463, :1163-1182)

  @Test("set_inbound_stamp_cost and the delivery announce match Python byte for byte")
  func deliveryAnnounce() throws {
    let transport = Transport()
    let router = LXMRouter(transport: transport)
    let delivery = try router.register(
      identity: Identity(), transport: transport, displayName: "Alice")
    for row in V.deliveryAnnounces {
      router.setInboundStampCost(destinationHash: delivery.hash, stampCost: nil)
      #expect(
        router.setInboundStampCost(destinationHash: delivery.hash, stampCost: row.cost)
          == row.accepted, "cost \(String(describing: row.cost))")
      #expect(
        router.getAnnounceAppData(destinationHash: delivery.hash)?.hexString == row.appData,
        "cost \(String(describing: row.cost))")
    }
  }

  @Test("set_inbound_stamp_cost refuses a destination that is not registered")
  func inboundCostUnregistered() {
    let router = LXMRouter(transport: Transport())
    #expect(
      !router.setInboundStampCost(destinationHash: Data(repeating: 1, count: 16), stampCost: 8))
  }

  @Test("stamp_cost_from_app_data prefers a numeric index 3")
  func deliveryCostReads() {
    for row in V.deliveryCostReads {
      #expect(stampCostFromAppData(Self.bytes(row.appData)) == row.cost, "\(row.appData)")
    }
  }

  // MARK: - The propagation node announce (LXMRouter.py:387-401, LXMF.py:229-272)

  @Test("the node announce carries ceilings at index 5 and fractional costs at index 7")
  func nodeAnnounce() {
    let router = LXMRouter(transport: Transport())
    for row in V.nodeAnnounces {
      router.propagationStampCost = row.costs[0]
      router.propagationStampCostFlexibility = row.costs[1]
      router.peeringCost = row.costs[2]
      let ours = Self.items(router.getPropagationNodeAppData())
      let theirs = Self.items(Self.bytes(row.appData))
      #expect(ours.count == 8)
      guard ours.count == 8, theirs.count == 8 else { continue }
      for index in [0, 2, 3, 4, 5] {
        #expect(MsgPack.encode(ours[index]) == MsgPack.encode(theirs[index]), "index \(index)")
      }
      #expect(Self.numbers(ours[7]) == Self.numbers(theirs[7]))
      #expect(Self.numbers(ours[7]) == row.costs)
    }
  }

  @Test("pn_announce_data_is_valid and pn_stamp_cost_from_app_data prefer index 7")
  func nodeCostReads() {
    for row in V.nodeCostReads {
      let appData = Self.bytes(row.appData)
      #expect(propagationNodeAnnounceDataIsValid(appData) == row.valid, "\(row.appData)")
      #expect(pnStampCostFromAppData(appData) == row.cost, "\(row.appData)")
    }
  }

  @Test("the node announce handler and offer handler take index 7's fractional costs")
  func nodeAnnounceParse() throws {
    let row = try #require(V.nodeAnnounces.first { $0.costs == [16.5, 2.25, 18.75] })
    let announce = try #require(PropagationNodeAnnounce(appData: Self.bytes(row.appData)))
    #expect(announce.stampCost == 16.5)
    #expect(announce.stampCostFlexibility == 2.25)
    #expect(announce.peeringCost == 18.75)
  }

  @Test("the outbound propagation cost is index 7's, clamped to STAMP_COST_CAP")
  func outboundPropagationCost() {
    let transport = Transport()
    let router = LXMRouter(transport: transport)
    let node = Data((0..<16).map { UInt8($0) + 0x70 })
    router.outboundPropagationNode = node
    func announced(_ costs: [MsgPack.Value], index7: [MsgPack.Value]?) {
      var items: [MsgPack.Value] = [
        .bool(false), .uint(1_700_000_000), .bool(true), .uint(256), .uint(10_240),
        .array(costs), .map([]),
      ]
      if let index7 { items.append(.array(index7)) }
      let identity = Identity()
      identity.appData = MsgPack.encode(.array(items))
      transport.restore(identity: identity, forDestination: node)
    }

    announced([.uint(17), .uint(3), .uint(18)], index7: [.double(16.5), .double(3), .double(18)])
    #expect(router.getOutboundPropagationCost() == 16.5)

    announced([.uint(250), .uint(3), .uint(18)], index7: nil)
    #expect(router.getOutboundPropagationCost() == Double(Transport.stampCostCap))
  }

  // MARK: - Defaults and configuration

  @Test("cost defaults are LXMF 1.3.0's (LXMRouter.py:63-67, :76)")
  func defaults() {
    #expect(LXMRouter.defaultPeeringCost == 18.0)
    #expect(LXMRouter.defaultMaxPeeringCost == 26.0)
    #expect(LXMRouter.propagationStampCostMin == 13.0)
    #expect(LXMRouter.defaultPropagationStampCostFlexibility == 3.0)
    #expect(LXMRouter.defaultPropagationStampCost == 16.0)
    #expect(LXMRouter.pnStampThrottle == 300)
    let router = LXMRouter(transport: Transport())
    #expect(router.pnStampThrottle == 300)
    router.pnStampThrottle = 900
    #expect(router.pnStampThrottle == 900)
  }

  @Test("the lxmd template documents float costs and the stamp throttle (lxmd.py:1038-1075)")
  func lxmdTemplate() {
    let template = LXMDConfig.exampleConfig
    for line in [
      "# propagation_stamp_cost_target = 16.0", "# propagation_stamp_cost_flexibility = 3.0",
      "# propagation_stamp_throttle = 5", "# peering_cost = 18.0",
      "# remote_peering_cost_max = 26.0",
    ] {
      #expect(template.contains(line), "\(line)")
    }
  }

  // MARK: - Destinations (LXMRouter.py:106, :216-217, :422, :631-635)

  @Test("the delivery destination's link cost is 3.25")
  func deliveryLinkCost() throws {
    let transport = Transport()
    let router = LXMRouter(transport: transport)
    let delivery = try router.register(identity: Identity(), transport: transport)
    #expect(delivery.getLinkCost(StampSettings()) == 3.25)
  }

  @Test("the propagation destination exists only once propagation is enabled, at link cost 3.25")
  func propagationDestination() throws {
    let transport = Transport()
    let router = LXMRouter(transport: transport)
    try router.register(identity: Identity(), transport: transport)
    #expect(router.propagationDestination == nil)

    let dir = NSTemporaryDirectory() + "lxmf_stampcost_\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try router.enablePropagation(storagePath: dir)
    let destination = try #require(router.propagationDestination)
    #expect(destination.getLinkCost(StampSettings()) == 3.25)
  }

  @Test("the router wants lxmf.delivery and lxmf.propagation from the destination-type filter")
  func wantsDestinationTypes() {
    let transport = Transport()
    let router = LXMRouter(transport: transport)
    for name in ["lxmf.delivery", "lxmf.propagation"] {
      #expect(transport.unwantsDestinationType(name, requester: transport.applicationIdentity.hash))
    }
    _ = router
  }
}
