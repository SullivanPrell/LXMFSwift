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

/// A router accepts transfers up to Python's default limits, not any size.
///
/// `DELIVERY_LIMIT = 1000`, `PROPAGATION_LIMIT = 256` and `SYNC_LIMIT = PROPAGATION_LIMIT*40`,
/// all in KB (`LXMRouter.py:68-73`), are the constructor defaults (`:112`). ReticulumSwift's
/// `ResourceTransfer` has no cap of its own, so a `nil` limit accepted a resource of any size.
final class TransferLimitDefaultsTests: XCTestCase {

  func testLimitsDefaultToPythons() {
    let router = LXMRouter(transport: Transport())
    XCTAssertEqual(router.deliveryPerTransferLimit, 1000)
    XCTAssertEqual(router.propagationPerTransferLimit, 256)
    XCTAssertEqual(router.propagationPerSyncLimit, 10240)
  }

  /// The client sends its delivery limit with a message request, as Python's does
  /// (`LXMRouter.py:1811-1813`).
  func testAClientAsksANodeForItsDeliveryLimit() throws {
    let router = LXMRouter(transport: Transport())
    XCTAssertEqual(router.messageGetLimitValue(), .int(1000))
    router.deliveryPerTransferLimit = nil
    XCTAssertEqual(router.messageGetLimitValue(), .nil)
  }
}
