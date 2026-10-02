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

/// Backchannel behavior captured from LXMF 1.2.0 on RNS 1.5.5, not computed by this package.
///
/// `scripts/capture-backchannel-vectors.py` runs the reference's own
/// `delivery_remote_identified`, `delivery_link_available` and `process_outbound` against
/// stand-in links, as a router holding identity A and sending to identity B. Captured
/// 2026-10-02.
enum PythonBackchannelVectors {

  /// `RNS.Identity.from_bytes(bytes(range(64)))`, the sender.
  static let identityAPrivateKey = Data((0..<64).map { UInt8($0) })

  /// `RNS.Identity.from_bytes(bytes(range(64, 128)))`, the receiver.
  static let identityBPrivateKey = Data((64..<128).map { UInt8($0) })

  /// Identity C, which the sender's router never registers.
  static let identityCPrivateKey = Data((128..<192).map { UInt8($0) })

  /// `id_a.get_public_key()`: what A identifies as after delivering a DIRECT message.
  static let identityAPublicKey =
    "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f"
    + "29acbae141bccaf0b22e1a94d34d0bc7361e526d0bfe12c89794bc9322966dd7"

  /// `hash_from_name_and_identity("lxmf.delivery", id_a)`: where the receiver files A's link.
  static let deliveryHashA = "fae321c442e3c9bdcd7a3e79d850e03c"

  /// `hash_from_name_and_identity("lxmf.delivery", id_b)`.
  static let deliveryHashB = "cf0b2a4a8d2a0b6978b71290da7cc80e"

  /// Identifications on one link after one, and after two, delivered DIRECT messages.
  static let identificationsAfterFirstDelivery = 1
  static let identificationsAfterSecondDelivery = 1

  /// Identifications after a delivered DIRECT message sent as a resource.
  static let identificationsAfterResourceDelivery = 1

  /// Identifications when the link isn't the initiator's, the source isn't a registered
  /// delivery identity, the message is opportunistic, or the link is a backchannel.
  static let identificationsOnResponderLink = 0
  static let identificationsForUnregisteredSource = 0
  static let identificationsForOpportunistic = 0
  static let identificationsOverBackchannel = 0

  /// `delivery_link_available` for an identified remote, an unknown hash, and a hash with
  /// only a direct link.
  static let availableForIdentifiedRemote = true
  static let availableForUnknown = false
  static let availableForDirectLinkOnly = true

  /// A DIRECT message with a backchannel and no direct link: sent on the backchannel, no
  /// attempt counted, no link constructed.
  static let backchannelSendAttempts = 0
  static let backchannelSendLinksConstructed = 0

  /// With both a direct link and a backchannel, the message goes on the direct link.
  static let preferredLink = "direct"

  /// A closed backchannel that had been active: available until a send finds it closed, then
  /// dropped, one path request, no attempt counted, the next attempt rescheduled.
  static let closedAvailableBefore = true
  static let closedAvailableAfter = false
  static let closedPathRequests = 1
  static let closedAttempts = 0
  static let closedRescheduled = true
}
