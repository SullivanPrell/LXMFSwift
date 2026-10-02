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

/// The router's path-request debounce and the waits derived from the slowest medium, against
/// LXMF 1.2.0 (`LXMRouter.py:1754-1792`).
///
/// The expected waits were read from LXMF 1.2.0's own methods on RNS 1.5.5, with the slowest
/// interface bitrate set to each value below.
@Suite("Path request debounce")
struct PathRequestDebounceTests {

  @Test("The debounce constants are the reference's")
  func constantsMatchTheReference() {
    #expect(LXMRouter.pathRequestDebounce == 60)
    #expect(LXMRouter.slowInterfaceBitrate == 2000)
  }

  @Test(
    "The path request wait is at least PATH_REQUEST_WAIT, and longer on a slow medium",
    arguments: [
      (1_000_000, 6.008, 7.0, false),
      (9600, 6.833_333, 7.0, false),
      (2000, 10.0, 10.0, false),
      (1999, 10.002_001, 10.002_001, true),
      (1200, 12.666_667, 12.666_667, true),
    ])
  func waitsFollowTheSlowestMedium(
    bitrate: Int, mediumTimeout: Double, wait: Double, slow: Bool
  ) throws {
    let node = try SingleNode()
    node.setSlowestBitrate(bitrate)
    #expect(abs(node.router.mediumPathTimeout() - mediumTimeout) < 0.000_01)
    #expect(abs(node.router.effectivePathRequestWait() - wait) < 0.000_01)
    #expect(node.router.slowInterfaceOnline() == slow)
  }

  @Test("A path request goes out once, and a repeat inside the wait is suppressed")
  func repeatInsideTheWaitIsSuppressed() throws {
    let node = try SingleNode()
    let destination = node.remoteDestination.hash

    #expect(node.router.requestPath(destination))
    #expect(!node.router.requestPath(destination))
    #expect(node.iface.sentPathRequests().count == 1)
  }

  @Test("A repeat after the wait has passed goes out")
  func repeatAfterTheWaitGoesOut() throws {
    let node = try SingleNode()
    let destination = node.remoteDestination.hash
    node.router.seedPathRequestTime(destination, Date().timeIntervalSince1970 - 8)

    #expect(node.router.requestPath(destination))
    #expect(node.iface.sentPathRequests().count == 1)
  }

  @Test("With a slow interface online, a repeat is suppressed for PATH_REQUEST_DEBOUNCE")
  func slowMediumWidensTheWindowToSixtySeconds() throws {
    let node = try SingleNode()
    node.setSlowestBitrate(1200)
    let destination = node.remoteDestination.hash
    let now = Date().timeIntervalSince1970

    node.router.seedPathRequestTime(destination, now - 30)
    #expect(!node.router.requestPath(destination))

    node.router.seedPathRequestTime(destination, now - 61)
    #expect(node.router.requestPath(destination))
    #expect(node.iface.sentPathRequests().count == 1)
  }

  @Test("A request outside the window is pruned when another is recorded")
  func expiredRequestsArePruned() throws {
    let node = try SingleNode()
    let stale = Data(repeating: 0x01, count: 16)
    node.router.seedPathRequestTime(stale, Date().timeIntervalSince1970 - 60)

    node.router.requestPath(node.remoteDestination.hash)

    let recorded = node.router.pathRequestTimesSnapshot()
    #expect(recorded[stale] == nil)
    #expect(recorded[node.remoteDestination.hash] != nil)
  }

  @Test("A request is pending for the path request wait, not the slow-medium debounce")
  func pendingUsesThePathRequestWait() throws {
    let node = try SingleNode()
    node.setSlowestBitrate(1200)
    let destination = node.remoteDestination.hash
    let now = Date().timeIntervalSince1970

    #expect(!node.router.pathRequestPending(destination))
    node.router.seedPathRequestTime(destination, now - 12)
    #expect(node.router.pathRequestPending(destination))
    node.router.seedPathRequestTime(destination, now - 13)
    #expect(!node.router.pathRequestPending(destination))
  }
}

extension SingleNode {
  /// Gives the recording interface `bitrate` and refreshes the transport's slowest-interface
  /// figure, as RNS does on its interface job (`Transport.py:1151`).
  func setSlowestBitrate(_ bitrate: Int) {
    iface.bitrate = bitrate
    transport.prioritizeInterfaces()
  }
}
