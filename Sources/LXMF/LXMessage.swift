import Foundation
import CoreImage
import ReticulumSwift

/// An LXMF message — the core envelope of the Lightweight Extensible
/// Messaging Format.
///
/// Wire format (mirrors Python's `LXMessage.pack()`):
///   [16 bytes] destination hash
///   [16 bytes] source hash
///   [64 bytes] Ed25519 signature
///   [N bytes]  msgpack([timestamp_f64, title_bytes, content_bytes, fields_dict, stamp?])
///
/// Signature covers: dest_hash + src_hash + msgpack(payload) + SHA256(above).
public final class LXMessage {

    // MARK: - State

    public enum State: UInt8 {
        case generating  = 0x00
        case outbound    = 0x01
        case sending     = 0x02
        case sent        = 0x04
        case delivered   = 0x08
        case rejected    = 0xFD
        case cancelled   = 0xFE
        case failed      = 0xFF
    }

    // MARK: - Representation

    public enum Representation: UInt8 {
        case unknown  = 0x00
        case packet   = 0x01
        case resource = 0x02
    }

    // MARK: - Delivery method

    public enum Method: UInt8 {
        case unknown      = 0x00
        case opportunistic = 0x01
        case direct       = 0x02
        case propagated   = 0x03
        case paper        = 0x05
    }

    // MARK: - Unverified reasons

    public enum UnverifiedReason: UInt8 {
        case sourceUnknown    = 0x01
        case signatureInvalid = 0x02
    }

    // MARK: - Wire-format sizes (matching Python constants)

    /// 16 bytes — truncated-hash length.
    public static let destinationLength = 16
    /// 64 bytes — Ed25519 signature length.
    public static let signatureLength   = 64
    /// 16 bytes — ticket length (same as destination hash).
    public static let ticketLength      = 16
    /// 8 bytes — f64 timestamp in msgpack payload.
    public static let timestampSize     = 8
    /// 8 bytes — msgpack array/map framing overhead per message.
    public static let structOverhead    = 8
    /// Total per-message overhead: 2×dest + sig + timestamp + struct.
    public static let lxmfOverhead     = 2 * destinationLength + signatureLength + timestampSize + structOverhead

    // MARK: - Properties

    public var destinationHash: Data
    public var sourceHash: Data

    /// The Destination the message was sent from (outbound) or implied by
    /// `sourceHash` (inbound). May be nil for received messages whose
    /// source identity is not locally known.
    public private(set) var destination: Destination?
    public private(set) var source: Destination?

    public var title: Data
    public var content: Data
    public var fields: [Int: Any]

    public var timestamp: TimeInterval?
    public private(set) var hash: Data?
    public private(set) var messageID: Data?
    public private(set) var signature: Data?
    public private(set) var packed: Data?

    /// Propagation-node wire format: msgpack([timestamp_f64, [lxmf_bytes]]).
    /// Matches Python's `LXMessage.propagation_packed`.
    /// Set by `pack()` alongside `packed`.
    public private(set) var propagationPacked: Data?

    /// Proof-of-work stamp (32 bytes). Set by `pack()` when `stampCost != nil`.
    /// Appended as index 4 of the msgpack payload array (after fields).
    /// Matches Python `LXMessage.stamp`.
    public private(set) var stamp: Data?

    /// Target stamp difficulty: minimum leading zero bits in SHA256(workblock+stamp).
    /// nil means no stamp is required/generated.
    public var stampCost: Int?

    /// HKDF expand rounds for stamp workblock. Defaults to `LXStamper.defaultExpandRounds`.
    public var stampExpandRounds: Int = LXStamper.defaultExpandRounds

    /// True if the stamp has been validated against `stampCost`.
    public private(set) var stampValid: Bool = false
    /// Leading zero bit count of the stamp (its "value"). Set by `validateStamp`.
    public private(set) var stampValue: Int?

    public var state: State = .generating
    public var method: Method = .unknown
    public var representation: Representation = .unknown
    public var desiredMethod: Method?

    public var incoming: Bool = false
    public var signatureValidated: Bool = false
    public var unverifiedReason: UnverifiedReason?
    public var transportEncrypted: Bool = false

    /// Human-readable description of the transport encryption in use.
    /// Mirrors Python's `LXMessage.transport_encryption` string attribute.
    /// Possible values: `"Curve25519"`, `"AES-128"`, `"Unencrypted"`, or `nil`.
    public var transportEncryptionDescription: String?

    // MARK: - Encryption description constants (mirrors Python class attrs)

    /// Python: `LXMessage.ENCRYPTION_DESCRIPTION_EC = "Curve25519"`
    public static let encryptionDescriptionEC          = "Curve25519"
    /// Python: `LXMessage.ENCRYPTION_DESCRIPTION_AES = "AES-128"`
    public static let encryptionDescriptionAES         = "AES-128"
    /// Python: `LXMessage.ENCRYPTION_DESCRIPTION_UNENCRYPTED = "Unencrypted"`
    public static let encryptionDescriptionUnencrypted = "Unencrypted"

    // MARK: - Ticket constants (mirrors Python class attrs)
    // Note: ticketLength = 16 is already defined above with the wire-format constants.

    /// Default ticket validity period: 21 days in seconds.
    /// Python: `LXMessage.TICKET_EXPIRY = 21*24*60*60`
    public static let ticketExpiry: TimeInterval = 21 * 24 * 60 * 60

    /// Grace period beyond expiry: 5 days in seconds.
    /// Python: `LXMessage.TICKET_GRACE = 5*24*60*60`
    public static let ticketGrace: TimeInterval = 5 * 24 * 60 * 60

    /// Minimum validity remaining before ticket auto-renews: 14 days in seconds.
    /// Python: `LXMessage.TICKET_RENEW = 14*24*60*60`
    public static let ticketRenew: TimeInterval = 14 * 24 * 60 * 60

    /// Minimum interval between ticket deliveries to the same peer: 1 day in seconds.
    /// Python: `LXMessage.TICKET_INTERVAL = 1*24*60*60`
    public static let ticketInterval: TimeInterval = 1 * 24 * 60 * 60

    /// Stamp value assigned when a ticket is used instead of proof-of-work: 256 (0x100).
    /// Python: `LXMessage.COST_TICKET = 0x100`
    public static let costTicket: Int = 0x100

    public var deliveryAttempts: Int = 0
    public var nextDeliveryAttempt: TimeInterval = 0
    public var progress: Double = 0

    /// An outbound ticket (`ticketLength` bytes) received from the destination router.
    /// When set and valid, `pack()` uses it to generate a cheap ticket-based stamp
    /// (`truncatedHash(ticket + messageID)`) instead of a full proof-of-work stamp.
    ///
    /// Mirrors Python's `LXMessage.outbound_ticket`.
    public var outboundTicket: Data?

    /// When `true`, the sending `LXMRouter` will generate an inbound ticket and
    /// include it in `fields[Field.ticket]` before packing, allowing the recipient
    /// to reply without spending proof-of-work compute.
    ///
    /// Mirrors Python's `LXMessage.include_ticket` init parameter.
    public var includeTicket: Bool = false

    /// Instance-level cache for the propagation-node PoW stamp.
    /// Must live in the class body (not an extension) since Swift extensions cannot
    /// hold stored properties. Using a static cache keyed by ObjectIdentifier was
    /// unsafe because Swift reuses memory addresses for newly-allocated objects,
    /// causing stale cache hits after an earlier message at the same address was
    /// deallocated.
    private var propagationStamp_: Data?

    /// Whether to auto-compress the resource when sending via RNS.Resource.
    /// Mirrors Python's `LXMessage.auto_compress`.
    public var autoCompress: Bool = true

    /// Whether this message originated from a source identity that is currently
    /// on the local blackhole list. Set during `unpack(_:)` after the source
    /// identity is recalled. The router drops blackholed messages before
    /// delivering them to the application.
    /// Mirrors Python's `LXMessage.source_blackholed`.
    public var sourceBlackholed: Bool = false

    public var onDelivery: ((LXMessage) -> Void)?
    public var onFailed: ((LXMessage) -> Void)?

    // MARK: - Init (outbound)

    public init(
        destination: Destination,
        source: Destination,
        content: Data = Data(),
        title: Data = Data(),
        fields: [Int: Any] = [:],
        desiredMethod: Method? = nil,
        stampCost: Int? = nil,
        stampExpandRounds: Int = LXStamper.defaultExpandRounds
    ) {
        self.destination = destination
        self.destinationHash = destination.hash
        self.source = source
        self.sourceHash = source.hash
        self.content = content
        self.title = title
        self.fields = fields
        self.desiredMethod = desiredMethod
        self.stampCost = stampCost
        self.stampExpandRounds = stampExpandRounds
    }

    public convenience init(
        destination: Destination,
        source: Destination,
        content: String,
        title: String = "",
        fields: [Int: Any] = [:],
        desiredMethod: Method? = nil,
        stampCost: Int? = nil,
        stampExpandRounds: Int = LXStamper.defaultExpandRounds
    ) {
        self.init(
            destination: destination,
            source: source,
            content: Data(content.utf8),
            title: Data(title.utf8),
            fields: fields,
            desiredMethod: desiredMethod,
            stampCost: stampCost,
            stampExpandRounds: stampExpandRounds
        )
    }

    // MARK: - String convenience

    public var contentAsString: String? { String(bytes: content, encoding: .utf8) }
    public var titleAsString: String?   { String(bytes: title, encoding: .utf8) }

    // MARK: - Packing (outbound)

    /// Pack the message into wire bytes. Sets `self.packed`, `self.hash`,
    /// `self.signature`, and selects `self.method`/`self.representation`.
    /// Mirrors Python's `LXMessage.pack()`.
    public func pack() throws {
        guard let source = source, let destination = destination else {
            throw LXMessageError.missingIdentity
        }
        guard let srcIdentity = source.identity, srcIdentity.hasPrivateKey else {
            throw LXMessageError.missingPrivateKey
        }

        let ts = timestamp ?? Date().timeIntervalSince1970
        if timestamp == nil { self.timestamp = ts }

        // Hash is computed from the 4-element payload (BEFORE stamp is appended).
        // Matches Python: hash covers [timestamp, title, content, fields] only.
        let corePayload = buildPayload(timestamp: ts, stamp: nil)

        var hashedPart = Data()
        hashedPart.append(destination.hash)
        hashedPart.append(source.hash)
        hashedPart.append(corePayload)

        let msgHash = Hashes.fullHash(hashedPart)
        self.hash = msgHash
        self.messageID = msgHash

        // Generate stamp after hash is known.
        // Priority: outbound ticket (cheap truncated-hash) > PoW stamp.
        // Mirrors Python's LXMessage.get_stamp():
        //   if outbound_ticket valid → truncated_hash(ticket + message_id)
        //   elif stamp_cost set      → LXStamper.generate_stamp(message_id, stamp_cost)
        if let ticket = outboundTicket,
           ticket.count == LXMessage.ticketLength {
            // Ticket-based stamp: truncatedHash(ticket ++ messageID) — 16 bytes.
            self.stamp      = Hashes.truncatedHash(ticket + msgHash)
            self.stampValue = LXMessage.costTicket
        } else if let cost = stampCost {
            self.stamp = LXStamper.generateStamp(
                messageID: msgHash,
                stampCost: cost,
                expandRounds: stampExpandRounds
            )
        }

        var signedPart = hashedPart
        signedPart.append(msgHash)
        self.signature = try srcIdentity.sign(signedPart)
        self.signatureValidated = true

        // Wire payload includes stamp as 5th element if present.
        let wirePayload = buildPayload(timestamp: ts, stamp: self.stamp)

        var wire = Data()
        wire.append(destination.hash)
        wire.append(source.hash)
        wire.append(self.signature!)
        wire.append(wirePayload)
        self.packed = wire

        // Propagation-node wire format: msgpack([timestamp, [dest_hash + encrypt(payload) + stamp]])
        // Python: lxmf_data = packed[:DEST_LEN] + destination.encrypt(packed[DEST_LEN:])
        //         if propagation_stamp: lxmf_data += propagation_stamp
        //         propagation_packed = msgpack([time.time(), [lxmf_data]])
        let destLen = LXMessage.destinationLength
        let payloadToEncrypt = Data(wire.dropFirst(destLen))
        let encryptedPayload = (try? destination.encrypt(payloadToEncrypt)) ?? payloadToEncrypt
        var lxmfData = destination.hash + encryptedPayload
        if let stamp = propagationStamp_ { lxmfData += stamp }
        self.propagationPacked = MsgPack.encode(.array([
            .double(ts),
            .array([.bytes(lxmfData)])
        ]))

        selectMethod(contentSize: corePayload.count - LXMessage.timestampSize - LXMessage.structOverhead)
    }

    private func buildPayload(timestamp: TimeInterval, stamp: Data? = nil) -> Data {
        var arr: [MsgPack.Value] = [
            .double(timestamp),
            .bytes(title),
            .bytes(content),
        ]
        if fields.isEmpty {
            arr.append(.nil)
        } else {
            var pairs: [(MsgPack.Value, MsgPack.Value)] = []
            for (k, v) in fields { pairs.append((.int(Int64(k)), msgpackValue(v))) }
            arr.append(.map(pairs))
        }
        if let s = stamp {
            arr.append(.bytes(s))
        }
        return MsgPack.encode(.array(arr))
    }

    private func msgpackValue(_ v: Any) -> MsgPack.Value {
        switch v {
        case let d as Data:    return .bytes(d)
        case let s as String:  return .bytes(Data(s.utf8))
        case let i as Int:     return .int(Int64(i))
        case let b as Bool:    return .bool(b)
        case let d as Double:  return .double(d)
        case let arr as [Any]: return .array(arr.map { msgpackValue($0) })
        default:               return .nil
        }
    }

    // MARK: - Field decoding (inbound)

    /// Convert a decoded msgpack map (payload element index 3) into the
    /// `[Int: Any]` representation used by `fields`. Inverse of the pack-side
    /// encoding in `buildPayload` (`(.int(Int64(k)), msgpackValue(v))`). Keys
    /// that aren't integers are skipped; values are decoded recursively.
    private static func decodeFields(_ pairs: [(MsgPack.Value, MsgPack.Value)]) -> [Int: Any] {
        var result: [Int: Any] = [:]
        for (key, value) in pairs {
            guard let k = decodeFieldKey(key) else { continue }
            result[k] = decodeFieldValue(value)
        }
        return result
    }

    /// Field keys are LXMF field IDs (`Field` raw values), packed as msgpack
    /// ints. Small positive ints decode as `.uint`, so both cases are handled.
    private static func decodeFieldKey(_ v: MsgPack.Value) -> Int? {
        switch v {
        case .int(let n):  return Int(exactly: n)
        case .uint(let n): return Int(exactly: n)
        default:           return nil
        }
    }

    /// Recursively convert a decoded msgpack value into the loosely-typed `Any`
    /// representation that field values use: `Data` for byte blobs, `Int`,
    /// `Bool`, `Double`, `String`, nested `[Any]` arrays (file attachments,
    /// tickets, etc.), and `[AnyHashable: Any]` maps (reactions, comments).
    private static func decodeFieldValue(_ v: MsgPack.Value) -> Any {
        switch v {
        case .nil:           return NSNull()
        case .bool(let b):   return b
        case .int(let n):    return Int(n)
        case .uint(let n):
            if let i = Int(exactly: n) { return i }
            return n
        case .double(let d): return d
        case .string(let s): return s
        case .bytes(let b):  return b
        case .array(let xs): return xs.map { decodeFieldValue($0) }
        case .map(let ps):
            var dict: [AnyHashable: Any] = [:]
            for (k, val) in ps {
                if let hk = decodeFieldMapKey(k) {
                    dict[hk] = decodeFieldValue(val)
                }
            }
            return dict
        }
    }

    /// Convert a decoded msgpack value into a hashable key for nested field
    /// maps. Skips array/map/nil keys, which LXMF never uses as map keys.
    private static func decodeFieldMapKey(_ v: MsgPack.Value) -> AnyHashable? {
        switch v {
        case .int(let n):    return Int(n)
        case .uint(let n):
            if let i = Int(exactly: n) { return i }
            return n
        case .string(let s): return s
        case .bytes(let b):  return b
        case .bool(let b):   return b
        case .double(let d): return d
        default:             return nil
        }
    }

    private func selectMethod(contentSize: Int) {
        // MDU constants (match Python defaults)
        let encryptedPacketMaxContent = 295  // RNS.Packet.ENCRYPTED_MDU + TIMESTAMP_SIZE - LXMF_OVERHEAD + DESTINATION_LENGTH
        let linkPacketMaxContent      = 319  // RNS.Link.MDU - LXMF_OVERHEAD

        let method = desiredMethod ?? .direct
        switch method {
        case .opportunistic:
            if contentSize <= encryptedPacketMaxContent {
                self.method = .opportunistic
                self.representation = .packet
            } else {
                self.method = .direct
                self.representation = contentSize <= linkPacketMaxContent ? .packet : .resource
            }
        case .direct:
            self.method = .direct
            self.representation = contentSize <= linkPacketMaxContent ? .packet : .resource
        case .propagated:
            self.method = .propagated
            self.representation = .packet
        default:
            self.method = .direct
            self.representation = contentSize <= linkPacketMaxContent ? .packet : .resource
        }
    }

    // MARK: - Unpacking (inbound)

    public enum LXMessageError: Error {
        case malformed
        case missingIdentity
        case missingPrivateKey
        case signatureInvalid
        case unknownSource
        /// Thrown by `asURI()` when `desiredMethod != .paper`.
        case notPaperMethod
        /// Thrown when packing fails unexpectedly.
        case packingFailed
        /// Thrown by `fromURI(_:)` or `ingestLXMURI(_:)` for malformed/wrong-scheme URIs.
        case invalidURI
    }

    /// Unpack a received wire blob into an LXMessage. Does NOT verify the
    /// signature — call `validateSignature(knownIdentity:)` afterwards.
    public static func unpack(_ data: Data) throws -> LXMessage {
        let hlen = destinationLength
        let slen = signatureLength
        let minLen = hlen + hlen + slen + 1
        guard data.count >= minLen else { throw LXMessageError.malformed }

        var cursor = 0
        let destHash = data[cursor ..< cursor + hlen]; cursor += hlen
        let srcHash  = data[cursor ..< cursor + hlen]; cursor += hlen
        let sig      = data[cursor ..< cursor + slen]; cursor += slen
        let payload  = data[cursor...]

        guard case .array(let parts) = try MsgPack.decode(Data(payload)),
              parts.count >= 3 else {
            throw LXMessageError.malformed
        }

        let ts: TimeInterval = {
            switch parts[0] {
            case .double(let d): return d
            case .uint(let n):   return TimeInterval(n)
            case .int(let n):    return TimeInterval(n)
            default:             return 0
            }
        }()
        let title: Data = {
            if case .bytes(let b) = parts[1] { return b }
            return Data()
        }()
        let content: Data = {
            if case .bytes(let b) = parts[2] { return b }
            return Data()
        }()

        // Extract stamp from 5th element if present. The message hash is computed
        // from only the first 4 elements (matches Python's unpack_from_bytes).
        let extractedStamp: Data? = {
            if parts.count >= 5, case .bytes(let b) = parts[4] { return b }
            return nil
        }()

        // Re-encode only the 4-element core payload for hash computation.
        let corePayload: Data
        if parts.count >= 5 {
            corePayload = MsgPack.encode(.array(Array(parts.prefix(4))))
        } else {
            corePayload = Data(payload)
        }

        let msg = LXMessage(
            destinationHash: Data(destHash),
            sourceHash: Data(srcHash),
            content: content,
            title: title
        )
        msg.timestamp = ts
        msg.signature = Data(sig)
        msg.stamp = extractedStamp
        msg.packed = data
        msg.incoming = true

        // Decode the fields dictionary (msgpack payload element index 3).
        // Python's `unpack_from_bytes` assigns `fields = unpacked_payload[3]`.
        // The inbound init defaults `fields` to empty, so without this every
        // received message would silently lose all of its fields — attachments,
        // telemetry, tickets, reactions, replies, commands, and the renderer
        // hint. Inverse of the pack-side encoding in `buildPayload`
        // (`(.int(Int64(k)), msgpackValue(v))`).
        if parts.count >= 4, case .map(let fieldPairs) = parts[3] {
            msg.fields = LXMessage.decodeFields(fieldPairs)
        }

        var hashedPart = Data()
        hashedPart.append(Data(destHash))
        hashedPart.append(Data(srcHash))
        hashedPart.append(corePayload)
        msg.hash = Hashes.fullHash(hashedPart)
        msg.messageID = msg.hash

        // Determine whether the source identity is currently blackholed.
        // Mirrors Python's `unpack_from_bytes` blackhole check (commit 2ac2b10).
        // `srcHash` is the sender's lxmf.delivery destination hash; we recall
        // the underlying Identity and check its hash against the blackhole list.
        // When `Reticulum.shared` is not initialised (test harness), or when
        // the source identity cannot be recalled, default to `false`.
        if let transport = Reticulum.shared?.transport,
           let srcIdentity = transport.recall(identity: Data(srcHash)),
           transport.isBlackholed(srcIdentity.hash) {
            msg.sourceBlackholed = true
        }

        return msg
    }

    /// Verify the signature against a known source identity. Returns true if
    /// valid, false if the signature doesn't match.
    @discardableResult
    public func validateSignature(knownIdentity: Identity) -> Bool {
        guard let sig = signature, let msgHash = hash, let packed = packed else { return false }
        let hlen = LXMessage.destinationLength
        let slen = LXMessage.signatureLength
        guard packed.count > hlen + hlen + slen else { return false }
        let rawPayload = packed.advanced(by: hlen + hlen + slen)

        // Strip stamp (5th element) if present — hash/signature covers only the 4-element payload.
        let corePayload: Data
        if let decoded = try? MsgPack.decode(rawPayload),
           case .array(let parts) = decoded, parts.count >= 5 {
            corePayload = MsgPack.encode(.array(Array(parts.prefix(4))))
        } else {
            corePayload = rawPayload
        }

        var hashedPart = Data()
        hashedPart.append(destinationHash)
        hashedPart.append(sourceHash)
        hashedPart.append(corePayload)
        var signedPart = hashedPart
        signedPart.append(msgHash)

        let valid = knownIdentity.validate(signature: sig, for: signedPart)
        signatureValidated = valid
        if !valid { unverifiedReason = .signatureInvalid }
        return valid
    }

    /// Validate the stamp against `targetCost`. Sets `stampValid` and `stampValue`.
    /// Uses `hash` (message_id) to reconstruct the workblock.
    /// Matches Python `LXMessage.validate_stamp`.
    @discardableResult
    /// Validate the message's stamp against the given cost.
    ///
    /// When `tickets` is provided, each ticket is tried first:
    /// `stamp == truncatedHash(ticket + messageID)`. On a match, `stampValue` is
    /// set to `costTicket` (0x100) and `true` is returned. If no ticket matches,
    /// falls through to the regular PoW workblock check.
    ///
    /// Mirrors Python's `LXMessage.validate_stamp(target_cost, tickets=None)`.
    public func validateStamp(targetCost: Int, tickets: [Data]? = nil) -> Bool {
        guard let s = stamp, let msgHash = hash else {
            stampValid = false
            return false
        }

        // Try ticket-based stamp validation first (mirrors Python's ticket loop).
        if let tickets {
            for ticket in tickets {
                if s == Hashes.truncatedHash(ticket + msgHash) {
                    stampValid = true
                    stampValue = LXMessage.costTicket
                    return true
                }
            }
        }

        // Fall through to PoW workblock validation.
        let workblock = LXStamper.stampWorkblock(material: msgHash, expandRounds: stampExpandRounds)
        let valid = LXStamper.stampValid(stamp: s, targetCost: targetCost, workblock: workblock)
        stampValid = valid
        if valid {
            stampValue = LXStamper.stampValue(workblock: workblock, stamp: s)
        }
        return valid
    }

    // MARK: - Private inbound init

    private init(
        destinationHash: Data,
        sourceHash: Data,
        content: Data,
        title: Data
    ) {
        self.destinationHash = destinationHash
        self.sourceHash = sourceHash
        self.content = content
        self.title = title
        self.fields = [:]
    }
}

extension LXMessage: CustomStringConvertible {
    public var description: String {
        if let h = hash {
            return "<LXMessage \(h.map { String(format: "%02x", $0) }.joined())>"
        }
        return "<LXMessage>"
    }
}

// MARK: - Python-parity convenience API

public extension LXMessage {

    // MARK: Constants

    /// URI scheme for paper-delivery LXMs. Python: `LXMessage.URI_SCHEMA = "lxm"`.
    static let uriSchema = "lxm"

    // MARK: QR code constants (Python: QR_MAX_STORAGE, QR_ERROR_CORRECTION, PAPER_MDU)

    /// Maximum byte capacity of a QR code with error correction level L.
    /// Python: `LXMessage.QR_MAX_STORAGE = 2953`
    public static let qrMaxStorage = 2953

    /// CIQRCodeGenerator correction level string for Error Correction Level L (~7%).
    /// Python: `LXMessage.QR_ERROR_CORRECTION = "ERROR_CORRECT_L"`
    public static let qrCorrectionLevel = "L"

    /// Maximum paper-delivery payload size (bytes) that fits in one QR code.
    /// Python: `PAPER_MDU = ((QR_MAX_STORAGE - (len(URI_SCHEMA) + len("://"))) * 6) // 8`
    public static let paperMDU: Int = {
        let uriPrefixLen = uriSchema.count + 3  // "lxm://" = 6
        return ((qrMaxStorage - uriPrefixLen) * 6) / 8
    }()

    // MARK: Title/Content setters

    /// Mirrors Python's `LXMessage.set_title_from_string(title_string)`.
    func setTitleFromString(_ string: String) { title = Data(string.utf8) }

    /// Mirrors Python's `LXMessage.set_title_from_bytes(title_bytes)`.
    func setTitleFromBytes(_ bytes: Data) { title = bytes }

    /// Mirrors Python's `LXMessage.set_content_from_string(content_string)`.
    func setContentFromString(_ string: String) { content = Data(string.utf8) }

    /// Mirrors Python's `LXMessage.set_content_from_bytes(content_bytes)`.
    func setContentFromBytes(_ bytes: Data) { content = bytes }

    // MARK: Fields

    /// Mirrors Python's `LXMessage.set_fields(fields)`.
    func setFields(_ newFields: [Int: Any]?) { fields = newFields ?? [:] }

    /// Mirrors Python's `LXMessage.get_fields()`.
    func getFields() -> [Int: Any]? { fields }

    // MARK: Paper URI encoding

    /// Encode a paper-delivery message as a `lxm://` URI.
    ///
    /// Mirrors Python's `LXMessage.as_uri()`.
    /// Throws `LXMessageError.notPaperMethod` if the desired method is not `.paper`.
    func asURI() throws -> String {
        guard desiredMethod == .paper else {
            throw LXMessageError.notPaperMethod
        }
        if packed == nil { try pack() }
        guard let raw = packed else { throw LXMessageError.packingFailed }
        // Python uses paper_packed (first 16 bytes dest hash + encrypted content)
        // For our purposes, packed is the wire bytes; encode them as-is.
        let b64 = raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(LXMessage.uriSchema)://\(b64)"
    }

    /// Encode a paper-delivery message as a QR code image (`CIImage`).
    ///
    /// Mirrors Python's `LXMessage.as_qr()`.
    /// Throws `LXMessageError.notPaperMethod` if the desired method is not `.paper`.
    ///
    /// The QR code encodes the `lxm://` URI of the message using error correction
    /// level L (low, ~7% correction), matching Python's `QR_ERROR_CORRECTION`.
    ///
    /// - Returns: A `CIImage` containing the raw (unscaled) QR code.
    ///   Scale up using `CGAffineTransform(scaleX:y:)` applied to the image before rendering.
    func asQR() throws -> CIImage {
        guard desiredMethod == .paper else {
            throw LXMessageError.notPaperMethod
        }
        if packed == nil { try pack() }
        let uri = try asURI()
        guard let msgData = uri.data(using: .utf8) else {
            throw LXMessageError.packingFailed
        }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw LXMessageError.packingFailed
        }
        filter.setValue(msgData, forKey: "inputMessage")
        filter.setValue(LXMessage.qrCorrectionLevel, forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else {
            throw LXMessageError.packingFailed
        }
        return image
    }

    /// Decode an LXM from a `lxm://` URI.
    ///
    /// Mirrors Python's `LXMRouter.ingest_lxm_uri()` decoding step.
    static func fromURI(_ uri: String) throws -> LXMessage {
        guard uri.hasPrefix(LXMessage.uriSchema + "://") else {
            throw LXMessageError.invalidURI
        }
        let encoded = String(uri.dropFirst(LXMessage.uriSchema.count + 3))
        // Restore base64 padding
        let padded = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padLen = (4 - padded.count % 4) % 4
        let paddedStr = padded + String(repeating: "=", count: padLen)
        guard let data = Data(base64Encoded: paddedStr) else {
            throw LXMessageError.invalidURI
        }
        return try LXMessage.unpack(data)
    }

    // MARK: - Transport encryption description

    /// Set `transportEncryptionDescription` based on `method` and `destination` type.
    ///
    /// Mirrors Python's `LXMessage.determine_transport_encryption()`.
    ///
    /// Possible outcomes:
    /// - `LXMessage.encryptionDescriptionEC`          ("Curve25519") for SINGLE destinations
    /// - `LXMessage.encryptionDescriptionAES`         ("AES-128")    for GROUP destinations
    /// - `LXMessage.encryptionDescriptionUnencrypted` ("Unencrypted") for PLAIN or unknown
    func determineTransportEncryption() {
        func descriptionForDestination(_ dest: Destination?) -> String {
            switch dest?.kind {
            case .single: return LXMessage.encryptionDescriptionEC
            case .group:  return LXMessage.encryptionDescriptionAES
            default:      return LXMessage.encryptionDescriptionUnencrypted
            }
        }

        switch method {
        case .opportunistic:
            transportEncrypted = (destination?.kind == .single || destination?.kind == .group)
            transportEncryptionDescription = descriptionForDestination(destination)
        case .direct:
            transportEncrypted = true
            transportEncryptionDescription = LXMessage.encryptionDescriptionEC
        case .propagated, .paper:
            transportEncrypted = (destination?.kind == .single || destination?.kind == .group)
            transportEncryptionDescription = descriptionForDestination(destination)
        default:
            transportEncrypted = false
            transportEncryptionDescription = LXMessage.encryptionDescriptionUnencrypted
        }
    }

    // MARK: - Propagation stamp (PoW for propagation-node delivery)

    /// Generate (or return cached) a proof-of-work stamp for propagation-node delivery.
    ///
    /// The stamp is computed over `messageID` (the message hash, set by `pack()`)
    /// using `LXStamper.pnExpandRounds` rounds — a reduced workblock versus the regular stamp.
    ///
    /// Returns `nil` if the message has not been packed yet (`messageID` is nil).
    ///
    /// Mirrors Python's `LXMessage.get_propagation_stamp(target_cost, timeout=None)`.
    func getPropagationStamp(targetCost: Int) -> Data? {
        // Return instance-cached stamp if already computed
        if let cached = propagationStamp_ { return cached }

        // Need messageID — only set after pack()
        guard let tid = messageID else { return nil }

        guard let stamp = LXStamper.generateStamp(
            messageID: tid,
            stampCost: targetCost,
            expandRounds: LXStamper.pnExpandRounds
        ) else { return nil }

        propagationStamp_ = stamp
        return stamp
    }

    /// Generate a Python-compatible propagation stamp and rebuild `propagationPacked`.
    ///
    /// Must be called AFTER `pack()` (which sets `messageID` and builds `propagationPacked`).
    ///
    /// Uses `LXStamper.generatePNStamp` (Python-compatible SHA-256 based workblock) so the
    /// stamp passes validation by a Python propagation node.  The `transient_id` is computed
    /// as `fullHash(lxmfDataWithoutStamp)` — identical to Python's `LXMessage.transient_id`.
    ///
    /// - Parameter cost: Minimum leading-zero-bit cost required by the propagation node.
    func attachPropagationStamp(cost: Int) {
        guard cost > 0 else { return }                  // mirrors Python: no stamp for cost ≤ 0
        guard propagationStamp_ == nil else { return }  // already stamped
        guard messageID != nil else { return }          // needs pack() first

        // Extract lxmfData (without stamp) from current propagationPacked.
        guard let pp = propagationPacked,
              case .array(let arr) = (try? MsgPack.decode(pp)),
              arr.count == 2,
              case .double(let ts) = arr[0],
              case .array(let msgs) = arr[1],
              !msgs.isEmpty,
              case .bytes(let lxmfDataNoStamp) = msgs[0]
        else { return }

        // transient_id = fullHash(lxmfDataWithoutStamp) — matches Python's LXMessage.transient_id.
        let transientID = Hashes.fullHash(lxmfDataNoStamp)

        // Generate PN stamp using the standard HKDF-based workblock (pnExpandRounds = 1000).
        // This matches Python's LXStamper.generate_stamp(transient_id, cost, expand_rounds=1000).
        guard let stamp = LXStamper.generateStamp(messageID: transientID, stampCost: cost,
                                                   expandRounds: LXStamper.pnExpandRounds)
        else { return }

        propagationStamp_ = stamp
        let newLxmfData = lxmfDataNoStamp + stamp
        propagationPacked = MsgPack.encode(.array([
            .double(ts),
            .array([.bytes(newLxmfData)])
        ]))
    }

    // MARK: File I/O

    /// Determine whether to auto-compress when sending via `RNS.Resource`.
    ///
    /// Checks `Identity.recallAppData(forDestination:)` and parses the
    /// compression-support flag from the announce `appData` using
    /// `compressionSupportFromAppData(_:)` (which mirrors Python's
    /// `compression_support_from_app_data`). Defaults to `true` when no
    /// app data is stored for the destination.
    ///
    /// Mirrors Python's `LXMessage.determine_compression_support()`.
    public func determineCompressionSupport() {
        if let appData = Identity.recallAppData(forDestination: destinationHash) {
            autoCompress = compressionSupportFromAppData(appData)
        } else {
            autoCompress = true
        }
    }

    // MARK: - Packed container (Python-compatible message store format)

    /// Build the msgpack container dict that Python stores on disk.
    ///
    /// Format (mirrors Python `LXMessage.packed_container()`):
    /// ```
    /// msgpack({
    ///   "lxmf_bytes":         <raw packed bytes>,
    ///   "state":              <state raw int>,
    ///   "transport_encrypted":<bool>,
    ///   "transport_encryption": <string or nil>,
    ///   "method":             <method raw int>,
    /// })
    /// ```
    ///
    /// This is the format that `write_to_directory` / `unpack_from_file`
    /// use in Python. Swift must match exactly for cross-implementation
    /// message-store interoperability.
    public func packedContainer() throws -> Data {
        if packed == nil { try pack() }
        guard let lxmfBytes = packed else { throw LXMessageError.packingFailed }

        var pairs: [(MsgPack.Value, MsgPack.Value)] = [
            (.string("state"),               .uint(UInt64(state.rawValue))),
            (.string("lxmf_bytes"),          .bytes(lxmfBytes)),
            (.string("transport_encrypted"), .bool(transportEncrypted)),
            (.string("method"),              .uint(UInt64(method.rawValue))),
        ]
        // Python includes transport_encryption as a string or None.
        // We include it when non-nil.
        if let enc = transportEncryptionDescription {
            pairs.append((.string("transport_encryption"), .string(enc)))
        } else {
            pairs.append((.string("transport_encryption"), .nil))
        }
        return MsgPack.encode(.map(pairs))
    }

    /// Read a packed LXMF message from a `FileHandle` and return the decoded
    /// `LXMessage`. The handle is read from its current position to EOF.
    ///
    /// Supports two on-disk formats:
    /// 1. **Container format** (Python-compatible): msgpack dict with `lxmf_bytes`,
    ///    `state`, `method`, `transport_encrypted`, `transport_encryption` keys.
    ///    Written by `writeToDirectory(_:)` and Python's `write_to_directory`.
    /// 2. **Raw format** (legacy): raw LXMF wire bytes (fallback for files written
    ///    by earlier Swift versions that didn't use the container format).
    ///
    /// Mirrors Python's `LXMessage.unpack_from_file(lxmf_file_handle)`.
    public static func unpackFromFile(_ handle: FileHandle) throws -> LXMessage {
        let raw = handle.readDataToEndOfFile()
        guard !raw.isEmpty else { throw LXMessageError.malformed }

        // Try container format first (Python-compatible)
        if let msg = tryUnpackContainer(raw) { return msg }
        // Fall back to raw packed bytes (legacy Swift format)
        return try LXMessage.unpack(raw)
    }

    /// Attempt to decode a Python-style packed container.
    /// Returns nil if `data` is not a msgpack map with `lxmf_bytes`.
    private static func tryUnpackContainer(_ data: Data) -> LXMessage? {
        guard case .map(let pairs) = (try? MsgPack.decode(data)) else { return nil }

        // Find "lxmf_bytes"
        guard let lxmfBytesVal = pairs.first(where: {
            if case .string(let s) = $0.0 { return s == "lxmf_bytes" }; return false
        })?.1, case .bytes(let lxmfBytes) = lxmfBytesVal else { return nil }

        guard let msg = try? LXMessage.unpack(lxmfBytes) else { return nil }

        // Restore optional fields from container
        if let stateVal = pairs.first(where: {
            if case .string(let s) = $0.0 { return s == "state" }; return false
        })?.1 {
            if case .uint(let v) = stateVal,
               let s = LXMessage.State(rawValue: UInt8(v)) { msg.state = s }
            else if case .int(let v) = stateVal, v >= 0,
               let s = LXMessage.State(rawValue: UInt8(v)) { msg.state = s }
        }

        if let methodVal = pairs.first(where: {
            if case .string(let s) = $0.0 { return s == "method" }; return false
        })?.1 {
            if case .uint(let v) = methodVal,
               let m = LXMessage.Method(rawValue: UInt8(v)) { msg.method = m }
            else if case .int(let v) = methodVal, v >= 0,
               let m = LXMessage.Method(rawValue: UInt8(v)) { msg.method = m }
        }

        if let teVal = pairs.first(where: {
            if case .string(let s) = $0.0 { return s == "transport_encrypted" }; return false
        })?.1, case .bool(let te) = teVal {
            msg.transportEncrypted = te
        }

        if let encVal = pairs.first(where: {
            if case .string(let s) = $0.0 { return s == "transport_encryption" }; return false
        })?.1, case .string(let enc) = encVal {
            msg.transportEncryptionDescription = enc
        }

        return msg
    }

    /// Write this message to a directory as a binary file named by its hash.
    ///
    /// Writes the Python-compatible **container format** (msgpack dict) so that
    /// files can be read by Python's `LXMessage.unpack_from_file()` and vice versa.
    ///
    /// Returns the file URL on success, `nil` on failure.
    ///
    /// Mirrors Python's `LXMessage.write_to_directory(directory_path)`.
    @discardableResult
    public func writeToDirectory(_ directory: URL) throws -> URL? {
        let containerData = try packedContainer()
        guard let h = hash else { return nil }
        let name = h.map { String(format: "%02x", $0) }.joined()
        let fileURL = directory.appendingPathComponent(name)
        // Tmp filename: include PID and 8 random bytes so two concurrent writes
        // to the same hash (e.g. from different threads or processes) cannot
        // collide. Mirrors Python's `write_to_directory` tmp name in LXMF
        // commit 5be161c: `name + ".tmp." + pid + "." + hex(urandom(8))`.
        var rndBytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, rndBytes.count, &rndBytes)
        let rndHex = rndBytes.map { String(format: "%02x", $0) }.joined()
        let tmpURL  = directory.appendingPathComponent(
            "\(name).tmp.\(ProcessInfo.processInfo.processIdentifier).\(rndHex)"
        )
        do {
            try containerData.write(to: tmpURL, options: .atomic)
            // Atomic replace — matches Python's os.replace(tmp_path, file_path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tmpURL, to: fileURL)
            return fileURL
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }
    }
}

