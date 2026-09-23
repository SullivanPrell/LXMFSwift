//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXMFSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import LXMF
import XCTest

/// Pins the 1.7.1 spellings that the style-guide renames replaced.
///
/// Each deprecated alias must resolve to the renamed declaration, so code written against
/// 1.7.1 compiles unchanged and reads the same value.
@available(*, deprecated, message: "Exercises deprecated aliases.")
final class DeprecatedNameAliasTests: XCTestCase {

  func testAppNameAlias() {
    XCTAssertEqual(APP_NAME, appName)
  }

  func testSupportedFunctionalityAlias() {
    XCTAssertEqual(SF_COMPRESSION, sfCompression)
  }

  func testPropagationNodeMetadataAliases() {
    XCTAssertEqual(PN_META_VERSION, pnMetaVersion)
    XCTAssertEqual(PN_META_NAME, pnMetaName)
    XCTAssertEqual(PN_META_SYNC_STRATUM, pnMetaSyncStratum)
    XCTAssertEqual(PN_META_SYNC_THROTTLE, pnMetaSyncThrottle)
    XCTAssertEqual(PN_META_AUTH_BAND, pnMetaAuthBand)
    XCTAssertEqual(PN_META_UTIL_PRESSURE, pnMetaUtilPressure)
    XCTAssertEqual(PN_META_CUSTOM, pnMetaCustom)
  }
}

/// Pins the 1.7.1 spelling of the `AudioMode` case names.
///
/// A static alias can't restore a renamed case to an exhaustive `switch`, so these names hold
/// until 2.0.0. The switch below lists every case and has no `default`; a rename fails to compile.
final class AudioModeCaseNameTests: XCTestCase {

  private func name(_ mode: AudioMode) -> String {
    switch mode {
    case .codec2_450PWB: return "codec2_450PWB"
    case .codec2_450: return "codec2_450"
    case .codec2_700C: return "codec2_700C"
    case .codec2_1200: return "codec2_1200"
    case .codec2_1300: return "codec2_1300"
    case .codec2_1400: return "codec2_1400"
    case .codec2_1600: return "codec2_1600"
    case .codec2_2400: return "codec2_2400"
    case .codec2_3200: return "codec2_3200"
    case .opusOgg: return "opusOgg"
    case .opusLBW: return "opusLBW"
    case .opusMBW: return "opusMBW"
    case .opusPTT: return "opusPTT"
    case .opusRTHDX: return "opusRTHDX"
    case .opusRTFDX: return "opusRTFDX"
    case .opusStandard: return "opusStandard"
    case .opusHQ: return "opusHQ"
    case .opusBroadcast: return "opusBroadcast"
    case .opusLossless: return "opusLossless"
    case .custom: return "custom"
    }
  }

  /// Raw values from `LXMF.py` `AM_CODEC2_*`.
  func testCodec2CasesKeepTheirRawValues() {
    let expected: [(AudioMode, UInt8)] = [
      (.codec2_450PWB, 0x01), (.codec2_450, 0x02), (.codec2_700C, 0x03),
      (.codec2_1200, 0x04), (.codec2_1300, 0x05), (.codec2_1400, 0x06),
      (.codec2_1600, 0x07), (.codec2_2400, 0x08), (.codec2_3200, 0x09),
    ]
    for (mode, raw) in expected {
      XCTAssertEqual(mode.rawValue, raw)
      XCTAssertEqual(AudioMode(rawValue: raw).map(name), name(mode))
    }
  }
}
