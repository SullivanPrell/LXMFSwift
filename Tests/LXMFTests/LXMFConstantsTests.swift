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
import Foundation
import LXMF
import ReticulumSwift

/// Covers the LXMF module-level constants and helper functions.
///
///   - sfCompression
///   - pnMeta* constants
///   - RENDERER_* constants
///   - pnNameFromAppData
///   - pnStampCostFromAppData
///   - LXMessage.ENCRYPTION_DESCRIPTION_* (already in LXMessage, tested here for coverage)
final class LXMFConstantsTests: XCTestCase {

    // MARK: - Supported Features

    func testSFCompressionIsZero() {
        XCTAssertEqual(sfCompression, 0x00)
    }

    // MARK: - Propagation Node Metadata keys

    func testPNMetaVersion() { XCTAssertEqual(pnMetaVersion,        0x00) }
    func testPNMetaName()    { XCTAssertEqual(pnMetaName,           0x01) }
    func testPNMetaSyncStratum() { XCTAssertEqual(pnMetaSyncStratum, 0x02) }
    func testPNMetaSyncThrottle() { XCTAssertEqual(pnMetaSyncThrottle, 0x03) }
    func testPNMetaAuthBand() { XCTAssertEqual(pnMetaAuthBand,     0x04) }
    func testPNMetaUtilPressure() { XCTAssertEqual(pnMetaUtilPressure, 0x05) }
    func testPNMetaCustom()  { XCTAssertEqual(pnMetaCustom,         0xFF) }

    // MARK: - Renderer mode constants

    func testRendererPlain()    { XCTAssertEqual(RendererMode.plain.rawValue,    0x00) }
    func testRendererMicron()   { XCTAssertEqual(RendererMode.micron.rawValue,   0x01) }
    func testRendererMarkdown() { XCTAssertEqual(RendererMode.markdown.rawValue, 0x02) }
    func testRendererBBCode()   { XCTAssertEqual(RendererMode.bbCode.rawValue,   0x03) }

    // MARK: - pnNameFromAppData

    func testPNNameFromAppDataNil() {
        XCTAssertNil(pnNameFromAppData(nil))
    }

    func testPNNameFromAppDataEmpty() {
        XCTAssertNil(pnNameFromAppData(Data()))
    }

    func testPNNameFromAppDataValidMsgpack() throws {
        // Build a valid PN announce app_data: msgpack array with at least 7 elements
        // [timebase_int, bool, int, int, [stamp_cost, flexibility, peering_cost], {pnMetaName: "TestNode"}]
        // Actually Python format: [display_name_bytes, timebase, enabled, transfer_limit, sync_limit,
        //                          [stamp_cost, flexibility, peering_cost], metadata_dict]
        let pairs: [(MsgPack.Value, MsgPack.Value)] = [
            (.uint(UInt64(pnMetaName)), .bytes(Data("TestNode".utf8)))
        ]
        let appData = MsgPack.encode(.array([
            .nil,              // display_name (unused in PN announce)
            .uint(1_000_000),  // timebase
            .bool(true),       // enabled
            .uint(100_000),    // transfer_limit
            .uint(50_000),     // sync_limit
            .array([.uint(5), .uint(1), .uint(3)]),  // [stamp_cost, flexibility, peering_cost]
            .map(pairs),       // metadata
        ]))
        let name = pnNameFromAppData(appData)
        XCTAssertEqual(name, "TestNode")
    }

    // MARK: - pnStampCostFromAppData

    func testPNStampCostFromAppDataNil() {
        XCTAssertNil(pnStampCostFromAppData(nil))
    }

    func testPNStampCostFromAppDataEmpty() {
        XCTAssertNil(pnStampCostFromAppData(Data()))
    }

    func testPNStampCostFromAppDataValidMsgpack() {
        // Same format as above — stamp_cost is at index 5[0]
        let appData = MsgPack.encode(.array([
            .nil,
            .uint(1_000_000),
            .bool(true),
            .uint(100_000),
            .uint(50_000),
            .array([.uint(7), .uint(2), .uint(3)]),
            .map([]),
        ]))
        let cost = pnStampCostFromAppData(appData)
        XCTAssertEqual(cost, 7)
    }

    // MARK: - LXMessage encryption description constants

    func testEncryptionDescEC() {
        XCTAssertEqual(LXMessage.encryptionDescriptionEC, "Curve25519")
    }

    func testEncryptionDescAES() {
        XCTAssertEqual(LXMessage.encryptionDescriptionAES, "AES-128")
    }

    func testEncryptionDescUnencrypted() {
        XCTAssertEqual(LXMessage.encryptionDescriptionUnencrypted, "Unencrypted")
    }
}
