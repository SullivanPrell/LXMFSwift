import Foundation
import CryptoKit
import ReticulumSwift

/// LXMF proof-of-work stamp computation.
/// Wire-compatible with Python's LXStamper.py.
///
/// Algorithm:
///   1. workblock = concat of `expandRounds` × HKDF(256 bytes, from=material, salt=SHA256(material+msgpack(n)))
///   2. stamp is valid when SHA256(workblock+stamp) has `targetCost` leading zero bits
///   3. stamp value = number of leading zero bits in SHA256(workblock+stamp)
public enum LXStamper {

    /// Default expand rounds for message stamps (matches Python WORKBLOCK_EXPAND_ROUNDS).
    public static let defaultExpandRounds: Int = 3000
    /// Default expand rounds for propagation-node stamps.
    public static let pnExpandRounds: Int = 1000

    /// Stamp byte length: 32 bytes (SHA-256 size).
    public static let stampSize: Int = 32

    /// Build the work block from `material` (typically the message_id / transient_id).
    /// Each round appends 256 bytes from HKDF:
    ///   HKDF(length=256, IKM=material, salt=SHA256(material + msgpack(round_index)), info=nil)
    public static func stampWorkblock(material: Data, expandRounds: Int = defaultExpandRounds) -> Data {
        var workblock = Data(capacity: expandRounds * 256)
        for n in 0 ..< expandRounds {
            let nPacked = encodeMsgpackInt(n)
            let salt = Hashes.fullHash(material + nPacked)
            let block = HKDF.derive(length: 256, derivedFrom: material, salt: salt)
            workblock.append(block)
        }
        return workblock
    }

    /// Count leading zero bits in SHA256(workblock + stamp). This is the "value" of the stamp.
    public static func stampValue(workblock: Data, stamp: Data) -> Int {
        let material = Hashes.fullHash(workblock + stamp)
        var count = 0
        for byte in material {
            if byte == 0 {
                count += 8
            } else {
                var b = byte
                while (b & 0x80) == 0 {
                    count += 1
                    b <<= 1
                }
                break
            }
        }
        return count
    }

    /// Returns true if SHA256(workblock + stamp) has at least `targetCost` leading zero bits.
    public static func stampValid(stamp: Data, targetCost: Int, workblock: Data) -> Bool {
        let result = Hashes.fullHash(workblock + stamp)
        return countLeadingZeroBits(result) >= targetCost
    }

    /// Generate a random 32-byte stamp whose SHA256(workblock + stamp) has `targetCost` leading zeros.
    /// Returns nil if cancelled (future: cancellation support). Runs on the calling thread.
    public static func generateStamp(messageID: Data, stampCost: Int, expandRounds: Int = defaultExpandRounds) -> Data? {
        let workblock = stampWorkblock(material: messageID, expandRounds: expandRounds)
        // Use incremental SHA-256 to avoid allocating workblock+stamp (up to 256KB) each iteration.
        // Pre-feed the workblock once and clone the hasher state for each stamp candidate.
        // CryptoKit's SHA256 does not expose copy(), so we hash workblock+stamp incrementally
        // using two update() calls — avoids the large Data concatenation.
        while true {
            var stamp = Data(count: stampSize)
            _ = stamp.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, stampSize, $0.baseAddress!)
            }
            // Incremental hash: SHA256(workblock || stamp) without allocating workblock+stamp.
            var hasher = SHA256()
            hasher.update(data: workblock)
            hasher.update(data: stamp)
            let digest = Data(hasher.finalize())
            if countLeadingZeroBits(digest) >= stampCost {
                return stamp
            }
        }
    }

    // MARK: - Helpers

    private static func countLeadingZeroBits(_ data: Data) -> Int {
        var count = 0
        for byte in data {
            if byte == 0 {
                count += 8
            } else {
                var b = byte
                while (b & 0x80) == 0 {
                    count += 1
                    b <<= 1
                }
                break
            }
        }
        return count
    }

    // MARK: - Propagation node stamp validation

    /// Expand rounds for propagation-node stamp validation (lower than message stamps).
    /// Python: `WORKBLOCK_EXPAND_ROUNDS_PN = 1000` (same as `pnExpandRounds`).
    public static let pnStampExpandRounds: Int = 1000


    /// Expand rounds for peering-key validation.
    /// Python: `WORKBLOCK_EXPAND_ROUNDS_PEERING = 25`.
    public static let peeringExpandRounds: Int = 25

    /// Validate a peering key for peer-to-peer sync.
    ///
    /// Mirrors Python's `validate_peering_key(peering_id, peering_key, target_cost)`.
    ///
    /// - Parameters:
    ///   - peeringID: Material = local_identity_hash + remote_identity_hash
    ///   - peeringKey: The stamp data to validate
    ///   - targetCost: Minimum required stamp value
    /// - Returns: true if the peering key is valid
    public static func validatePeeringKey(peeringID: Data, peeringKey: Data, targetCost: Int) -> Bool {
        let workblock = stampWorkblock(material: peeringID, expandRounds: peeringExpandRounds)
        return stampValid(stamp: peeringKey, targetCost: targetCost, workblock: workblock)
    }

    /// Validate a single propagation-node stamp on incoming message data.
    ///
    /// Mirrors Python's `validate_pn_stamp(transient_data, target_cost)`.
    ///
    /// - Parameters:
    ///   - transientData: Raw LXMF bytes + appended 32-byte stamp
    ///   - targetCost: Minimum required stamp value
    /// - Returns: (transientID, lxmfData, stampValue, stamp) on success, nil on failure
    public static func validatePNStamp(transientData: Data, targetCost: Int) ->
            (transientID: Data, lxmfData: Data, stampValue: Int, stamp: Data)? {
        // Minimum = LXMF overhead + stamp
        let minLen = LXMessage.lxmfOverhead + stampSize
        guard transientData.count > minLen else { return nil }

        let lxmfData   = transientData.prefix(transientData.count - stampSize)
        let stamp      = transientData.suffix(stampSize)
        let transientID = Hashes.fullHash(lxmfData)
        let workblock  = stampWorkblock(material: transientID, expandRounds: pnStampExpandRounds)

        guard stampValid(stamp: stamp, targetCost: targetCost, workblock: workblock) else {
            return nil
        }
        let value = stampValue(workblock: workblock, stamp: stamp)
        return (transientID: transientID,
                lxmfData:    Data(lxmfData),
                stampValue:  value,
                stamp:       Data(stamp))
    }

    /// Validate a list of raw transient_data entries for propagation node acceptance.
    ///
    /// Mirrors Python's `validate_pn_stamps(transient_list, target_cost)`.
    ///
    /// - Returns: Array of (transientID, lxmfData, stampValue, stamp) for each valid entry.
    public static func validatePNStamps(
        transientList: [Data], targetCost: Int
    ) -> [(transientID: Data, lxmfData: Data, stampValue: Int, stamp: Data)] {
        transientList.compactMap { validatePNStamp(transientData: $0, targetCost: targetCost) }
    }

    /// Encode an integer as msgpack. Matches Python `umsgpack.packb(n)` for non-negative n.
    /// Used in workblock salt computation to match Python wire format exactly.
    static func encodeMsgpackInt(_ n: Int) -> Data {
        var out = Data()
        if n <= 0x7F {
            out.append(UInt8(n))
        } else if n <= 0xFF {
            out.append(0xCC); out.append(UInt8(n))
        } else if n <= 0xFFFF {
            out.append(0xCD)
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
        } else if n <= 0xFFFF_FFFF {
            out.append(0xCE)
            out.append(UInt8((n >> 24) & 0xFF))
            out.append(UInt8((n >> 16) & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
        } else {
            out.append(0xCF)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((n >> shift) & 0xFF))
            }
        }
        return out
    }
}
