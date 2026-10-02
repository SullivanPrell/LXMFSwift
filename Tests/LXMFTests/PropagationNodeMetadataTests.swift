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

/// The metadata map a propagation node announces, against LXMF 1.2.0.
///
/// `get_propagation_node_announce_metadata` writes the implementation name under
/// `PN_META_IMPL_NAME` (0xFE) and the version under `PN_META_VERSION`, both as msgpack strings,
/// then the node name, if one is set, as bytes under `PN_META_NAME` (`LXMRouter.py:325-330`).
/// LXMF 1.2.0 on RNS 1.5.5 packs `{0xFE: "lxmd", 0x00: "1.2.0", 0x01: b"Node"}` as
/// `83 ccfe a46c786d64 00 a5312e322e30 01 c4044e6f6465`.
@Suite("Propagation node announce metadata")
struct PropagationNodeMetadataTests {

  @Test("PN_META_IMPL_NAME is 0xFE")
  func implNameKeyMatchesTheReference() {
    #expect(pnMetaImplName == 0xFE)
  }

  @Test("The package records the LXMF release it matches")
  func protocolVersionIsTheReferenceRelease() {
    #expect(lxmfProtocolVersion == "1.2.0")
  }

  @Test("The metadata carries the implementation, the version and the name, in Python's layout")
  func metadataBytesFollowTheReferenceLayout() throws {
    let node = try SingleNode()
    node.router.name = "Node"

    let appData = node.router.getPropagationNodeAppData()
    guard case .array(let fields) = try MsgPack.decode(appData), fields.count == 7 else {
      Issue.record("the announce data is not a seven-element array")
      return
    }

    var expected = Data([0x83, 0xCC, 0xFE])
    expected.append(Self.str(pnImplementationName))
    expected.append(0x00)
    expected.append(Self.str(lxmfSwiftVersion))
    expected.append(contentsOf: [0x01, 0xC4, 0x04])
    expected.append(Data("Node".utf8))
    #expect(MsgPack.encode(fields[6]) == expected)
  }

  @Test("A node without a name leaves PN_META_NAME out")
  func unnamedNodeOmitsTheName() throws {
    let node = try SingleNode()
    for name in [nil, ""] as [String?] {
      node.router.name = name
      let metadata = node.router.getPropagationNodeAnnounceMetadata()
      #expect(metadata.count == 2)
      #expect(!metadata.contains { $0.0 == .uint(UInt64(pnMetaName)) })
    }
  }

  @Test("The announced name reads back through pnNameFromAppData")
  func announcedNameReadsBack() throws {
    let node = try SingleNode()
    node.router.name = "Relay"
    #expect(pnNameFromAppData(node.router.getPropagationNodeAppData()) == "Relay")
  }

  /// A msgpack `fixstr` or `str8`, as `umsgpack` packs a short Python `str`.
  static func str(_ value: String) -> Data {
    let bytes = Data(value.utf8)
    var out =
      bytes.count < 32
      ? Data([0xA0 | UInt8(bytes.count)]) : Data([0xD9, UInt8(bytes.count)])
    out.append(bytes)
    return out
  }
}
