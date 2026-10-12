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

/// A delivery announce reads `awaiting_path` and writes `next_delivery_attempt` on the
/// announce thread while the outbound pass schedules the same messages on another
/// (`Handlers.py:23-26`, `LXMRouter.py:1803-1813`).
///
/// ThreadSanitizer is the oracle: run with `swift test --sanitize=thread`.
@Suite("Announce and outbound pass race")
struct AnnounceAwaitingPathRaceTests {

  @Test("A delivery announce and an outbound pass touch a message's schedule without a race")
  func announceRacesOutboundPass() throws {
    let node = try SingleNode()
    // Past MAX_PATHLESS_TRIES with no path, so each due pass requests a path and sets
    // `awaitingPath` (`LXMRouter.py:2811-2817`).
    let messages = try (0..<32).map { _ in
      let message = try node.enqueueMessage(method: .opportunistic)
      message.deliveryAttempts = LXMRouter.maxPathlessTries
      return message
    }

    DispatchQueue.concurrentPerform(iterations: 2) { worker in
      for _ in 0..<200 {
        if worker == 0 {
          node.router.processOutbound()
        } else {
          node.router.handleAnnounceForDestination(node.remoteDestination.hash)
        }
      }
    }

    #expect(messages.allSatisfy { $0.deliveryAttempts > LXMRouter.maxPathlessTries })
  }
}
