//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXMFSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import XCTest

@testable import LXMF

final class LXMFVersionTests: XCTestCase {
  /// The constant is announced in propagation node metadata, so a release must move it.
  func testVersionMatchesTheRelease() {
    XCTAssertEqual(lxmfSwiftVersion, "1.15.0")
  }
}
