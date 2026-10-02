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

/// A propagation download that has to wait for a path, against LXMF 1.2.0.
///
/// `request_messages_from_propagation_node` requests the path and starts
/// `request_messages_path_job`, which polls until the path arrives or
/// `max(PR_PATH_TIMEOUT, path_request_wait())` passes (`LXMRouter.py:541-547`, `:1464-1477`).
@Suite("Propagation download path wait")
struct PropagationDownloadPathTests {

  @Test("The download waits PR_PATH_TIMEOUT for a path on a fast medium")
  func fastMediumWaitsTheFixedTimeout() throws {
    let node = try SingleNode()
    node.router.outboundPropagationNode = Data(repeating: 0xAB, count: 16)
    let before = Date().timeIntervalSince1970

    node.router.requestMessagesFromPropagationNode(identity: Identity())

    let timeout = try #require(node.router.wantsDownloadOnPathAvailableTimeout)
    #expect(abs(timeout - before - LXMRouter.prPathTimeout) < 0.5)
    #expect(node.router.wantsDownloadOnPathAvailableTo != nil)
  }

  @Test("The download waits the path request wait when that is longer")
  func slowMediumWaitsThePathRequestWait() throws {
    let node = try SingleNode()
    node.setSlowestBitrate(1000)
    node.router.outboundPropagationNode = Data(repeating: 0xAB, count: 16)
    let before = Date().timeIntervalSince1970

    node.router.requestMessagesFromPropagationNode(identity: Identity())

    // 2 * (500 * 8 / 1000) + 6 = 14 seconds (`Transport.py:3205-3208`).
    let timeout = try #require(node.router.wantsDownloadOnPathAvailableTimeout)
    #expect(abs(timeout - before - 14) < 0.5)
  }

  @Test("A download whose path never arrives fails when the wait runs out")
  func noPathByTheTimeoutFailsTheSync() throws {
    let node = try SingleNode()
    node.router.outboundPropagationNode = Data(repeating: 0xAB, count: 16)
    node.router.requestMessagesFromPropagationNode(identity: Identity())
    let timeout = try #require(node.router.wantsDownloadOnPathAvailableTimeout)

    #expect(!node.router.checkDownloadPath(now: timeout - 1))
    #expect(node.router.propagationTransferState == .pathRequested)

    #expect(node.router.checkDownloadPath(now: timeout + 0.1))
    #expect(node.router.propagationTransferState == .failed)
    #expect(node.router.wantsDownloadOnPathAvailableFrom == nil)
  }
}
