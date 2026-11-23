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

/// Who a propagation node serves, and how much.
///
/// `message_get_request` refuses an identity off the allow list when auth is on
/// (`LXMRouter.py:1702-1704`) and reads the client's limit with `float(data[2])`, which takes an
/// integer (`:1747-1751`). `offer_request` postpones a sync while stamps are being validated or
/// while `MAX_INBOUND_SYNCS` resources are arriving (`:2610-2618`).
final class PropagationNodeAccessTests: XCTestCase {

  private var tempDir: String!

  override func setUp() {
    super.setUp()
    tempDir = NSTemporaryDirectory() + "lxmf_pnaccess_\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: tempDir)
    super.tearDown()
  }

  private func makeNode() throws -> LXMRouter {
    let router = LXMRouter(transport: Transport())
    try router.enablePropagation(storagePath: tempDir)
    return router
  }

  private func errorCode(_ value: MsgPack.Value) -> LXMPeerError? { LXMPeerError(msgPack: value) }

  /// Stores one message of `size` bytes on disk for `destination` and returns its transient ID.
  @discardableResult
  private func store(_ router: LXMRouter, for destination: Data, size: Int, fill: UInt8) -> Data {
    let body = destination + Data(repeating: fill, count: size - destination.count)
    let tid = Hashes.fullHash(body)
    router.addToMessageStore(
      lxmfData: body, transientID: tid, stampValue: 8,
      stamp: Data(repeating: 0x33, count: LXStamper.stampSize))
    return tid
  }

  // MARK: - Auth on /get

  func testAuthRefusesAnIdentityOffTheAllowList() throws {
    let router = try makeNode()
    let client = Identity()
    let delivery = Data(repeating: 0x44, count: LXMessage.destinationLength)
    store(router, for: delivery, size: 200, fill: 1)
    router.setAuthentication(required: true)

    let refused = router.handleMessageGetRequest(
      data: .array([.nil, .nil]), remoteDeliveryHash: delivery, remoteIdentityHash: client.hash)
    XCTAssertEqual(errorCode(refused), .noAccess)

    router.allow(identityHash: client.hash)
    let served = router.handleMessageGetRequest(
      data: .array([.nil, .nil]), remoteDeliveryHash: delivery, remoteIdentityHash: client.hash)
    guard case .array(let ids) = served else { return XCTFail("expected the message list") }
    XCTAssertEqual(ids.count, 1)
  }

  func testWithoutAuthAnyIdentityIsServed() throws {
    let router = try makeNode()
    let delivery = Data(repeating: 0x44, count: LXMessage.destinationLength)
    store(router, for: delivery, size: 200, fill: 1)
    let served = router.handleMessageGetRequest(
      data: .array([.nil, .nil]), remoteDeliveryHash: delivery,
      remoteIdentityHash: Identity().hash)
    guard case .array(let ids) = served else { return XCTFail("expected the message list") }
    XCTAssertEqual(ids.count, 1)
  }

  // MARK: - The client's download limit

  /// Two 600-byte messages and a 1 KB limit: the first fits (24 + 616), the second doesn't.
  func testAnIntegerClientLimitIsHonoured() throws {
    let router = try makeNode()
    let delivery = Data(repeating: 0x45, count: LXMessage.destinationLength)
    let first = store(router, for: delivery, size: 568, fill: 1)
    let second = store(router, for: delivery, size: 568, fill: 2)
    let want = MsgPack.Value.array([.bytes(first), .bytes(second)])

    func served(_ limit: MsgPack.Value) -> Int {
      // A fresh copy each time: serving doesn't remove, only a "have" does.
      guard
        case .array(let messages) = router.handleMessageGetRequest(
          data: .array([want, .nil, limit]), remoteDeliveryHash: delivery)
      else { return -1 }
      return messages.count
    }

    XCTAssertEqual(served(.nil), 2, "reference: no limit serves both")
    XCTAssertEqual(served(.double(1)), 1, "reference: a float limit serves one")
    XCTAssertEqual(served(.int(1)), 1, "Python and Swift clients both send the limit as an int")
    XCTAssertEqual(served(.uint(1)), 1)
  }

  // MARK: - Inbound sync throttling

  private func offer(_ router: LXMRouter, from propagationHash: Data) -> MsgPack.Value {
    router.peeringCost = 0
    return router.handleOfferRequest(
      data: .array([.bytes(Data(count: 32)), .array([.bytes(Data(repeating: 9, count: 32))])]),
      remoteIdentityHash: Identity().hash, propagationHash: propagationHash,
      linkID: ObjectIdentifier(self))
  }

  func testAnOfferWaitsWhileAnotherBatchIsValidated() throws {
    let router = try makeNode()
    let remote = Data(repeating: 0x71, count: 16)
    XCTAssertEqual(offer(router, from: remote), .bool(true), "reference: an idle node accepts")

    router.seedValidatingPNStamps(from: Data(repeating: 0x72, count: 16))
    XCTAssertEqual(errorCode(offer(router, from: remote)), .throttled)

    router.propagationSequentialValidation = false
    XCTAssertEqual(offer(router, from: remote), .bool(true))
  }

  func testAStaticPeerBypassesSequentialValidation() throws {
    let router = try makeNode()
    let staticPeer = Data(repeating: 0x73, count: 16)
    router.addStaticPeer(staticPeer)
    router.seedValidatingPNStamps(from: Data(repeating: 0x72, count: 16))
    XCTAssertEqual(offer(router, from: staticPeer), .bool(true))

    router.propagationStaticPeerSequential = true
    XCTAssertEqual(errorCode(offer(router, from: staticPeer)), .throttled)
  }

  func testAnOfferWaitsWhileMaxInboundSyncsAreTransferring() throws {
    let router = try makeNode()
    let remote = Data(repeating: 0x74, count: 16)
    XCTAssertEqual(router.propagationMaxInboundSyncs, 3)
    // Held, so no two identifiers share a freed address.
    let links = (0..<4).map { _ in NSObject() }
    for link in links[0..<2] { router.seedAcceptedOffer(ObjectIdentifier(link), .transferring) }
    router.seedAcceptedOffer(ObjectIdentifier(links[2]), .accepted)
    XCTAssertEqual(offer(router, from: remote), .bool(true), "only transferring offers count")

    router.seedAcceptedOffer(ObjectIdentifier(links[3]), .validating)
    XCTAssertEqual(errorCode(offer(router, from: remote)), .throttled)
  }

  /// `offer_request` records a partly wanted offer, which `propagation_resource_advertised`
  /// then counts as transferring (`LXMRouter.py:2564-2568`, `:2656-2657`).
  func testAPartlyWantedOfferIsRecordedAsAccepted() throws {
    let router = try makeNode()
    let held = store(router, for: Data(repeating: 0x46, count: 16), size: 200, fill: 3)
    let link = NSObject()
    let linkID = ObjectIdentifier(link)
    router.peeringCost = 0
    _ = router.handleOfferRequest(
      data: .array([
        .bytes(Data(count: 32)), .array([.bytes(held), .bytes(Data(repeating: 9, count: 32))]),
      ]),
      remoteIdentityHash: Identity().hash, propagationHash: Data(repeating: 0x75, count: 16),
      linkID: linkID)
    XCTAssertEqual(router.acceptedOfferState(linkID), .accepted)
    withExtendedLifetime(link) {}
  }
}
