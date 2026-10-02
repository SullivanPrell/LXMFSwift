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

/// The largest message that travels as one opportunistic packet, against LXMF 1.2.0.
///
/// LXMF 1.2.0 drops `TIMESTAMP_SIZE` from `ENCRYPTED_PACKET_MDU` (`LXMessage.py:65-79`), so the
/// single-packet content limit falls from 295 bytes to 287. The expected values were read from
/// LXMF 1.2.0 on RNS 1.5.5: `ENCRYPTED_PACKET_MDU` 383, `ENCRYPTED_PACKET_MAX_CONTENT` 287,
/// `LINK_PACKET_MAX_CONTENT` 319.
@Suite("Single-packet size limits")
struct SinglePacketSizeTests {

  @Test("The encrypted packet MDU is RNS's encrypted MDU, with no timestamp added")
  func encryptedPacketMDUIsTheRNSValue() {
    #expect(LXMessage.encryptedPacketMDU == 383)
    #expect(LXMessage.encryptedPacketMDU == Packet.encryptedMdu)
  }

  @Test("The single-packet content limit is 287 bytes, and the link packet limit is 319")
  func contentLimitsMatchTheReference() {
    #expect(LXMessage.encryptedPacketMaxContent == 287)
    #expect(LXMessage.linkPacketMaxContent == 319)
  }

  @Test("287 bytes of content go as one opportunistic packet")
  func contentAtTheLimitStaysOpportunistic() throws {
    let message = try Self.packedMessage(contentSize: 287)
    #expect(message.method == .opportunistic)
    #expect(message.representation == .packet)
  }

  @Test("288 bytes of content fall back to a direct link packet")
  func contentOverTheLimitGoesDirect() throws {
    let message = try Self.packedMessage(contentSize: 288)
    #expect(message.method == .direct)
    #expect(message.representation == .packet)
  }

  @Test("A group destination's transport encryption is described as AES-256")
  func groupEncryptionIsDescribedAsAES256() {
    #expect(LXMessage.encryptionDescriptionAES == "AES-256")
  }

  /// Packs an opportunistic message whose content size, as `LXMessage.pack` measures it, is
  /// `contentSize`.
  ///
  /// The measure is the msgpack payload less `TIMESTAMP_SIZE` and `STRUCT_OVERHEAD`
  /// (`LXMessage.py:393`). With an empty title and no fields, content of 256 bytes or more
  /// carries a three-byte `bin16` header, so the measure equals the content length.
  static func packedMessage(contentSize: Int) throws -> LXMessage {
    precondition(contentSize >= 256)
    let source = try Destination(
      identity: Identity(), direction: .in, kind: .single,
      appName: "lxmf", aspects: ["delivery"])
    let destination = try Destination(
      identity: Identity(), direction: .in, kind: .single,
      appName: "lxmf", aspects: ["delivery"])
    let message = LXMessage(
      destination: destination, source: source,
      content: Data(repeating: 0x61, count: contentSize),
      desiredMethod: .opportunistic)
    try message.pack()
    return message
  }
}
