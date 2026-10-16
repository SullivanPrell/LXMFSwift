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

/// `LXMRouter.clean_message_store` (`LXMRouter.py:1152-1222`, LXMF 1.2.0 at `c3ff2d6`):
/// expire entries older than `MESSAGE_EXPIRY`, then cull by `get_weight`, heaviest first.
@Suite("Message store cleaning")
struct MessageStoreCleaningTests {

  static let day: TimeInterval = 24 * 60 * 60

  static func hash(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

  static func propagationRouter() throws -> (LXMRouter, String) {
    let dir = NSTemporaryDirectory() + "lxmf_store_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let router = LXMRouter(transport: Transport())
    try router.enablePropagation(storagePath: dir)
    return (router, dir)
  }

  static func seed(
    _ router: LXMRouter, _ byte: UInt8, ageDays: Double, size: Int, destination: Data? = nil
  ) -> Data {
    let tid = hash(byte)
    router.seedPropagationEntry(
      tid,
      PropagationEntry(
        destinationHash: destination ?? hash(byte ^ 0xF0), filePath: "/nonexistent/\(byte)",
        received: Date().timeIntervalSince1970 - ageDays * day, msgSize: size))
    return tid
  }

  @Test("an entry older than 30 days is purged with no storage limit set")
  func expiresWithoutLimit() throws {
    let (router, dir) = try Self.propagationRouter()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    #expect(router.messageStorageLimit == nil)
    let expired = Self.seed(router, 0x01, ageDays: 31, size: 100)
    let fresh = Self.seed(router, 0x02, ageDays: 29, size: 100)

    router.cleanMessageStore()

    #expect(router.propagationEntries[expired] == nil)
    #expect(router.propagationEntries[fresh] != nil)
  }

  @Test("over the limit, the heaviest entry goes first, not the oldest")
  func cullsByWeight() throws {
    let (router, dir) = try Self.propagationRouter()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    router.setMessageStorageLimit(kilobytes: 1)
    let prioritised = Self.hash(0xA1)
    router.prioritise(destinationHash: prioritised)
    // Weights (`LXMRouter.py:1064-1075`): 0.1 * 1 * 600 = 60 and 1.0 * 1 * 600 = 600.
    let older = Self.seed(router, 0x01, ageDays: 1, size: 600, destination: prioritised)
    let heavier = Self.seed(router, 0x02, ageDays: 0.04, size: 600)

    router.cleanMessageStore()

    #expect(router.propagationEntries[heavier] == nil)
    #expect(router.propagationEntries[older] != nil)
  }
}
