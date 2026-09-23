//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXMFSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

// swift-format-ignore-file: AlwaysUseLowerCamelCase

// Spellings public in 1.7.1, kept so 1.x stays source-compatible. Remove in 2.0.0.

/// Deprecated spelling of ``appName``.
@available(*, deprecated, renamed: "appName")
public var APP_NAME: String { appName }

/// Deprecated spelling of ``sfCompression``.
@available(*, deprecated, renamed: "sfCompression")
public var SF_COMPRESSION: UInt8 { sfCompression }

/// Deprecated spelling of ``pnMetaVersion``.
@available(*, deprecated, renamed: "pnMetaVersion")
public var PN_META_VERSION: UInt8 { pnMetaVersion }

/// Deprecated spelling of ``pnMetaName``.
@available(*, deprecated, renamed: "pnMetaName")
public var PN_META_NAME: UInt8 { pnMetaName }

/// Deprecated spelling of ``pnMetaSyncStratum``.
@available(*, deprecated, renamed: "pnMetaSyncStratum")
public var PN_META_SYNC_STRATUM: UInt8 { pnMetaSyncStratum }

/// Deprecated spelling of ``pnMetaSyncThrottle``.
@available(*, deprecated, renamed: "pnMetaSyncThrottle")
public var PN_META_SYNC_THROTTLE: UInt8 { pnMetaSyncThrottle }

/// Deprecated spelling of ``pnMetaAuthBand``.
@available(*, deprecated, renamed: "pnMetaAuthBand")
public var PN_META_AUTH_BAND: UInt8 { pnMetaAuthBand }

/// Deprecated spelling of ``pnMetaUtilPressure``.
@available(*, deprecated, renamed: "pnMetaUtilPressure")
public var PN_META_UTIL_PRESSURE: UInt8 { pnMetaUtilPressure }

/// Deprecated spelling of ``pnMetaCustom``.
@available(*, deprecated, renamed: "pnMetaCustom")
public var PN_META_CUSTOM: UInt8 { pnMetaCustom }
