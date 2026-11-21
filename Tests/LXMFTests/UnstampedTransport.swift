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

extension Transport {
  /// A transport that sends its own announces and path requests unstamped and synchronously.
  ///
  /// RNS 1.6.1 stamps both by default (`Transport.py:194-195`), which grinds a stamp on a
  /// background queue before the packet leaves. Tests about routing and delivery rather than
  /// stamps use this transport so their announces and path requests go out before the next line
  /// runs.
  static func unstamped() -> Transport {
    let transport = Transport()
    transport.stamps.stampDestinations = false
    transport.stamps.stampPRs = false
    return transport
  }
}
