import Foundation

/// LXMF application name — used for Destination naming.
public let APP_NAME = "lxmf"

// MARK: - Field identifiers (mirrors LXMF/LXMF.py)

public enum Field: UInt8 {
    case embeddedLXMs       = 0x01
    case telemetry          = 0x02
    case telemetryStream    = 0x03
    case iconAppearance     = 0x04
    case fileAttachments    = 0x05
    case image              = 0x06
    case audio              = 0x07
    case thread             = 0x08  // Bytes, full thread ID hash
    case commands           = 0x09
    case results            = 0x0A
    case group              = 0x0B
    case ticket             = 0x0C
    case event              = 0x0D
    case rnrRefs            = 0x0E
    case renderer           = 0x0F
    case replyTo            = 0x30  // Bytes, full LXMessage.hash
    case replyQuote         = 0x31  // Bytes, quoted content in UTF-8 encoding
    case reaction           = 0x40  // Dict, see ReactionField indices
    case comment            = 0x41  // Dict, see CommentField indices
    case continuation       = 0x42  // Dict, see ContinuationField indices
    case customType         = 0xFB
    case customData         = 0xFC
    case customMeta         = 0xFD
    case nonSpecific        = 0xFE
    case debug              = 0xFF
}

// MARK: - Reaction dict indices (mirrors LXMF.py REACTION_TO / REACTION_CONTENT)

public enum ReactionField: UInt8 {
    case reactionTo      = 0x00  // Python: REACTION_TO — Bytes, full LXMessage.hash
    case reactionContent = 0x01  // Python: REACTION_CONTENT — Bytes, reaction content in UTF-8
}

// MARK: - Comment dict indices (mirrors LXMF.py COMMENT_FOR)

public enum CommentField: UInt8 {
    case commentFor = 0x00  // Python: COMMENT_FOR — Bytes, full LXMessage.hash
}

// MARK: - Continuation dict indices (mirrors LXMF.py CONTINUATION_OF)

public enum ContinuationField: UInt8 {
    case continuationOf = 0x00  // Python: CONTINUATION_OF — Bytes, full LXMessage.hash
}

// MARK: - Audio mode identifiers

public enum AudioMode: UInt8 {
    case codec2_450PWB  = 0x01
    case codec2_450     = 0x02
    case codec2_700C    = 0x03
    case codec2_1200    = 0x04
    case codec2_1300    = 0x05
    case codec2_1400    = 0x06
    case codec2_1600    = 0x07
    case codec2_2400    = 0x08
    case codec2_3200    = 0x09
    case opusOgg        = 0x10
    case opusLBW        = 0x11
    case opusMBW        = 0x12
    case opusPTT        = 0x13
    case opusRTHDX      = 0x14
    case opusRTFDX      = 0x15
    case opusStandard   = 0x16
    case opusHQ         = 0x17
    case opusBroadcast  = 0x18
    case opusLossless   = 0x19
    case custom         = 0xFF
}

/// Decode a display name from LXMF announcement `appData`.
///
/// Mirrors Python's `LXMF.display_name_from_app_data()`. For version 0.5.0+
/// msgpack format the first array element is decoded as UTF-8 with null bytes
/// stripped and the result trimmed of whitespace (matching the `.replace("\x00",
/// "").strip()` applied in Python 0.9.9+). For legacy raw-UTF-8 appData the
/// bytes are decoded directly.
///
/// Returns `nil` when `appData` is absent, empty, or cannot be decoded.
public func displayNameFromAppData(_ appData: Data?) -> String? {
    guard let appData, !appData.isEmpty else { return nil }
    // Version 0.5.0+ announce format: msgpack array, first element is display name
    if (appData[0] >= 0x90 && appData[0] <= 0x9F) || appData[0] == 0xDC {
        guard case .array(let items) = (try? ReticulumSwift.MsgPack.decode(appData)),
              let first = items.first else { return nil }
        // Accept both bin (.bytes) and str (.string) — Python 3 sends bin,
        // Python 2 / compatibility-mode senders use the legacy str type.
        let rawBytes: Data
        switch first {
        case .bytes(let b) where !b.isEmpty: rawBytes = b
        case .string(let s) where !s.isEmpty:
            guard let d = s.data(using: .utf8) else { return nil }
            rawBytes = d
        default: return nil
        }
        return String(bytes: rawBytes, encoding: .utf8)?
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespaces)
            .nilIfEmpty
    }
    // Original announce format: raw UTF-8 bytes
    return String(bytes: appData, encoding: .utf8)?.nilIfEmpty
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Decode `stamp_cost` from LXMF delivery announcement `appData`.
///
/// The delivery announce format is `[display_name, stamp_cost, supported_functionality]`
/// (version 0.5.0+). Stamp cost is at index **1**, not 0.
///
/// Mirrors Python's `stamp_cost_from_app_data` which returns `peer_data[1]`.
public func stampCostFromAppData(_ appData: Data?) -> Int? {
    guard let appData, !appData.isEmpty else { return nil }
    guard case .array(let items) = (try? ReticulumSwift.MsgPack.decode(appData)),
          items.count >= 2 else { return nil }
    switch items[1] {
    case .int(let n):  return Int(n)
    case .uint(let n): return Int(n)
    default: return nil
    }
}

/// Validate that propagation node announce data is a well-formed msgpack array
/// with the expected minimum element count.
/// Mirrors Python's `pn_announce_data_is_valid`.
public func propagationNodeAnnounceDataIsValid(_ appData: Data?) -> Bool {
    guard let appData else { return false }
    guard case .array(let items) = (try? ReticulumSwift.MsgPack.decode(appData)),
          items.count >= 7 else { return false }
    return true
}

/// Whether auto-compression is advertised in the announce `appData`.
/// Mirrors Python's `compression_support_from_app_data`. Defaults to `true`
/// when the appData is absent, empty, or uses the legacy raw-UTF-8 format.
/// For 0.5.0+ msgpack format: returns `true` when the array has fewer than 3
/// elements, when `items[2]` is not an array, or when `items[2]` contains
/// `SF_COMPRESSION`.
public func compressionSupportFromAppData(_ appData: Data?) -> Bool {
    guard let appData, !appData.isEmpty else { return true }
    let firstByte = appData[appData.startIndex]
    // Version 0.5.0+ announce format: msgpack array
    if (firstByte >= 0x90 && firstByte <= 0x9F) || firstByte == 0xDC {
        guard case .array(let items) = (try? ReticulumSwift.MsgPack.decode(appData)) else { return true }
        if items.count < 3 { return true }
        guard case .array(let funcs) = items[2] else { return true }
        return funcs.contains { value in
            switch value {
            case .uint(let n): return n == UInt64(SF_COMPRESSION)
            case .int(let n):  return n == Int64(SF_COMPRESSION)
            default: return false
            }
        }
    }
    // Original (pre-0.5.0) announce format: raw UTF-8 — always supported
    return true
}

// MARK: - Supported functionality codes (mirrors LXMF.py SF_* constants)

/// Supported functionality code indicating bzip2 compression support.
/// Python: `SF_COMPRESSION = 0x00`
public let SF_COMPRESSION: UInt8 = 0x00

// MARK: - Propagation Node metadata keys (mirrors LXMF.py PN_META_* constants)

/// Python: `PN_META_VERSION = 0x00`
public let PN_META_VERSION:       UInt8 = 0x00
/// Python: `PN_META_NAME = 0x01`
public let PN_META_NAME:          UInt8 = 0x01
/// Python: `PN_META_SYNC_STRATUM = 0x02`
public let PN_META_SYNC_STRATUM:  UInt8 = 0x02
/// Python: `PN_META_SYNC_THROTTLE = 0x03`
public let PN_META_SYNC_THROTTLE: UInt8 = 0x03
/// Python: `PN_META_AUTH_BAND = 0x04`
public let PN_META_AUTH_BAND:     UInt8 = 0x04
/// Python: `PN_META_UTIL_PRESSURE = 0x05`
public let PN_META_UTIL_PRESSURE: UInt8 = 0x05
/// Python: `PN_META_CUSTOM = 0xFF`
public let PN_META_CUSTOM:        UInt8 = 0xFF

// MARK: - Message renderer modes (mirrors LXMF.py RENDERER_* constants)

/// Mirrors Python `RENDERER_PLAIN/MICRON/MARKDOWN/BBCODE` constants.
public enum RendererMode: UInt8 {
    case plain    = 0x00   // Python: RENDERER_PLAIN
    case micron   = 0x01   // Python: RENDERER_MICRON
    case markdown = 0x02   // Python: RENDERER_MARKDOWN
    case bbCode   = 0x03   // Python: RENDERER_BBCODE
}

// MARK: - Propagation node app_data helpers

/// Decode the propagation node's display name from its announce `appData`.
///
/// Mirrors Python's `pn_name_from_app_data(app_data)`. The PN announce format
/// is a msgpack array where `data[6]` is a metadata dict; `PN_META_NAME` (0x01)
/// holds the node name as UTF-8 bytes.
///
/// Returns `nil` when `appData` is absent, malformed, or the name is not set.
public func pnNameFromAppData(_ appData: Data?) -> String? {
    guard let appData, !appData.isEmpty else { return nil }
    guard propagationNodeAnnounceDataIsValid(appData),
          case .array(let items) = (try? MsgPack.decode(appData)),
          items.count >= 7,
          case .map(let pairs) = items[6] else { return nil }
    let nameEntry = pairs.first { if case .uint(let k) = $0.0 { return k == UInt64(PN_META_NAME) }; return false }
    guard let entry = nameEntry, case .bytes(let b) = entry.1, !b.isEmpty else { return nil }
    return String(bytes: b, encoding: .utf8)
}

/// Decode the propagation node's stamp cost from its announce `appData`.
///
/// Mirrors Python's `pn_stamp_cost_from_app_data(app_data)`. The stamp cost
/// is at `data[5][0]` in the PN announce array.
///
/// Returns `nil` when `appData` is absent or malformed.
public func pnStampCostFromAppData(_ appData: Data?) -> Int? {
    guard let appData, !appData.isEmpty else { return nil }
    guard propagationNodeAnnounceDataIsValid(appData),
          case .array(let items) = (try? MsgPack.decode(appData)),
          items.count >= 6,
          case .array(let costs) = items[5],
          !costs.isEmpty else { return nil }
    switch costs[0] {
    case .int(let n):  return Int(n)
    case .uint(let n): return Int(n)
    default: return nil
    }
}

// Publicly re-export ReticulumSwift types so callers can write
// `import LXMF` without also importing ReticulumSwift.
@_exported import ReticulumSwift
