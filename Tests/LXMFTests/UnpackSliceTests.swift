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
import LXMF
import ReticulumSwift
import Testing

/// A `Data` slice keeps its parent's indices, so `unpack` has to read from `startIndex`.
@Suite("LXMessage.unpack on a slice")
struct UnpackSliceTests {

  @Test("a packed message unpacks from a slice that doesn't start at 0")
  func unpacksFromAnOffsetSlice() throws {
    let src = try Destination(
      identity: Identity(), direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
    let dst = try Destination(
      identity: Identity(), direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
    let message = LXMessage(destination: dst, source: src, content: "slice", title: "t")
    try message.pack()
    let packed = try #require(message.packed)

    let wire = try LXMessage.unpack((Data([0xFF]) + packed).dropFirst())

    #expect(wire.destinationHash == dst.hash)
    #expect(wire.sourceHash == src.hash)
    #expect(wire.content == Data("slice".utf8))
    #expect(wire.packed == packed)
    #expect(wire.packed?.startIndex == 0, "packed keeps the slice's offset indices")
  }
}
