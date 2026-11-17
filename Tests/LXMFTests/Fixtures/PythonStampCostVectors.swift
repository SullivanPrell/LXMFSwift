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

/// Stamp and stamp-cost behavior captured from LXMF 1.3.0 on RNS 1.6.0, not computed by this package.
///
/// `scripts/capture-stamp-cost-vectors.py` calls the reference's own `RNS.Stamps` and `LXStamper`
/// functions, `LXMF.py` readers and router methods, with the network denied. Captured 2026-11-14.
enum PythonStampCostVectors {

  /// The material every stamp in `stamps` is over: `bytes(range(32))`.
  static let material = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

  /// A cost and whether `stamp_valid` accepts the stamp at it.
  struct Validity {
    let cost: Double
    let valid: Bool
  }

  /// The first `full_hash(i)` reaching 6 over each LXMF workblock (`LXStamper.py:16-18`).
  struct Stamp {
    let rounds: Int
    let stamp: String
    let value: Double
    let validity: [Validity]
  }

  static let stamps: [Stamp] = [
    .init(
      rounds: 3000, stamp: "743221d05652b873fdb35c3874a72d4bdff695e700bea2ef669d4088ded21ba7",
      value: 6.2265625,
      validity: [
        .init(cost: 6.22265625, valid: true), .init(cost: 6.2265625, valid: true),
        .init(cost: 6.23046875, valid: false), .init(cost: 6.0, valid: true),
        .init(cost: 7.0, valid: false),
      ]),
    .init(
      rounds: 1000, stamp: "a7911cdfdc28e6a1867e359ba426081aacfa692fdeb3e978d2a68dd924fa8c3e",
      value: 6.66796875,
      validity: [
        .init(cost: 6.6640625, valid: true), .init(cost: 6.66796875, valid: true),
        .init(cost: 6.671875, valid: false), .init(cost: 6.0, valid: true),
        .init(cost: 7.0, valid: false),
      ]),
    .init(
      rounds: 25, stamp: "ca3076acbb6ec2b695ebf174caa57ef3f8421707948a72029cc3836b9572c9d7",
      value: 9.578125,
      validity: [
        .init(cost: 9.57421875, valid: true), .init(cost: 9.578125, valid: true),
        .init(cost: 9.58203125, valid: false), .init(cost: 9.0, valid: true),
        .init(cost: 10.0, valid: false),
      ]),
  ]

  /// `validate_pn_stamp(lxm_data + stamp, cost)` (`LXStamper.py:31-43`): the value, or `nil`.
  static let pnLXMData =
    "000102030405060708090a0b0c0d0e0f6465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7"
  static let pnStamp = "bc2d9ddc9857e53598677dbea82a2583879e89ce6c032c77d825187bf3f1a943"
  static let pnResults: [(cost: Double, value: Double?)] = [
    (5.140625, 5.14453125),
    (5.14453125, 5.14453125),
    (5.1484375, nil),
  ]

  /// `validate_peering_key(peering_id, key, cost)` (`LXStamper.py:26-29`).
  static let peeringID = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
  static let peeringKey = "dd31255fc43e0b47b0dcf462b0a065bfde18563965f198a36862dc76c7f046cc"
  static let peeringResults: [Validity] = [
    .init(cost: 8.64453125, valid: true),
    .init(cost: 8.6484375, valid: true),
    .init(cost: 8.65234375, valid: false),
  ]

  /// `f"_{quantize_cost(value)}"`, the message-store filename's value component (`LXMRouter.py:2874-2877`).
  static let storeValueComponents: [(value: Double, component: String)] = [
    (1.0, "_1.0"),
    (16.0, "_16.0"),
    (16.5, "_16.5"),
    (8.3, "_8.30078125"),
    (13.00390625, "_13.00390625"),
  ]

  /// `quantize_cost(component)`, how the index reads a stored filename back (`LXMRouter.py:656`).
  static let storeValueReads: [(component: String, value: Double)] = [
    ("16", 16.0),
    ("16.0", 16.0),
    ("16.5", 16.5),
    ("8.30078125", 8.30078125),
    ("8.3", 8.30078125),
  ]

  /// `set_inbound_stamp_cost(cost)` after a reset to `None`, then `get_announce_app_data` for a
  /// destination named "Alice" (`LXMRouter.py:444-463`, `:1163-1182`).
  struct DeliveryAnnounce {
    let cost: Double?
    let accepted: Bool
    let stored: Double?
    let appData: String
  }

  static let deliveryAnnounces: [DeliveryAnnounce] = [
    .init(cost: nil, accepted: true, stored: nil, appData: "94c405416c696365c09100c0"),
    .init(cost: 0.0, accepted: true, stored: nil, appData: "94c405416c696365c09100c0"),
    .init(cost: 0.5, accepted: true, stored: nil, appData: "94c405416c696365c09100c0"),
    .init(
      cost: 1.0, accepted: true, stored: 1.0, appData: "94c405416c696365019100cb3ff0000000000000"),
    .init(
      cost: 1.0, accepted: true, stored: 1.0, appData: "94c405416c696365019100cb3ff0000000000000"),
    .init(
      cost: 8.0, accepted: true, stored: 8.0, appData: "94c405416c696365089100cb4020000000000000"),
    .init(
      cost: 8.5, accepted: true, stored: 8.5, appData: "94c405416c696365099100cb4021000000000000"),
    .init(
      cost: 8.3, accepted: true, stored: 8.3, appData: "94c405416c696365099100cb40209a0000000000"),
    .init(
      cost: 99.9, accepted: true, stored: 99.9, appData: "94c405416c696365649100cb4058f98000000000"),
    .init(cost: 100.0, accepted: false, stored: nil, appData: "94c405416c696365c09100c0"),
    .init(cost: 255.0, accepted: false, stored: nil, appData: "94c405416c696365c09100c0"),
    .init(cost: -3.0, accepted: true, stored: nil, appData: "94c405416c696365c09100c0"),
  ]

  /// `get_propagation_node_app_data()` with the stamp costs set.
  ///
  /// `LXMRouter.py:387-401`. Index 1 is the capture time, and index 6 names the implementation.
  static let nodeAnnounces: [(costs: [Double], appData: String)] = [
    (
      [16.0, 3.0, 18.0],
      "98c2ce6af8a880c2cd0100cd28009310031282ccfea46c786d6400a5312e332e3093cb4030000000000000cb4008000000000000cb4032000000000000"
    ),
    (
      [16.5, 2.25, 18.75],
      "98c2ce6af8a880c2cd0100cd28009311031382ccfea46c786d6400a5312e332e3093cb4030800000000000cb4002000000000000cb4032c00000000000"
    ),
    (
      [13.0, 0.0, 26.0],
      "98c2ce6af8a880c2cd0100cd2800930d001a82ccfea46c786d6400a5312e332e30930d001a"
    ),
  ]

  /// `stamp_cost_from_app_data(app_data)` (`LXMF.py:183-199`).
  static let deliveryCostReads: [(appData: String, cost: Double?)] = [
    ("94c40141099100cb4021000000000000", 8.5),
    ("94c4014109910007", 7.0),
    ("94c40141099100c0", 9.0),
    ("94c40141099100a178", 9.0),
    ("94c40141099100c3", 9.0),
    ("93c40141099100", 9.0),
    ("94c40141c09100c0", nil),
    ("95c40141099100cb4021000000000000a56578747261", 8.5),
  ]

  /// `pn_announce_data_is_valid` and `pn_stamp_cost_from_app_data` (`LXMF.py:229-272`).
  static let nodeCostReads: [(appData: String, valid: Bool, cost: Double?)] = [
    ("97c2ce6553f100c3cd0100cd28009310031280", true, 16.0),
    (
      "98c2ce6553f100c3cd0100cd2800931003128093cb4030800000000000cb4002000000000000cb4032c00000000000",
      true, 16.5
    ),
    (
      "97c2ce6553f100c3cd0100cd280093cb4030800000000000cb4008000000000000cb403200000000000080",
      true, 16.5
    ),
    (
      "99c2ce6553f100c3cd0100cd2800931003128093cb4030800000000000cb4002000000000000cb4032c00000000000a56578747261",
      true, 16.5
    ),
    ("98c2ce6553f100c3cd0100cd28009310031280a178", false, nil),
    ("98c2ce6553f100c3cd0100cd2800931003128093a1610102", false, nil),
    ("98c2ce6553f100c3cd0100cd2800931003128093c00102", false, nil),
    ("98c2ce6553f100c3cd0100cd2800931003128092cb4030800000000000cb4002000000000000", false, nil),
  ]
}
