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
    /// Returns nil if cancelled. Runs on the calling thread.
    ///
    /// Thin wrapper over `generateStamp(material:targetCost:expandRounds:isCancelled:)`, which is
    /// the form the peering path needs — Python's `generate_stamp` returns `(stamp, value)` and the
    /// peer stores both (`LXStamper.py:123-144`, `LXMPeer.py:259-261`).
    public static func generateStamp(messageID: Data, stampCost: Int,
                                     expandRounds: Int = defaultExpandRounds) -> Data? {
        generateStamp(material: messageID, targetCost: stampCost,
                      expandRounds: expandRounds)?.stamp
    }

    /// Generate a stamp over `material` and report the value it actually reached.
    ///
    /// Mirrors Python's `generate_stamp(message_id, stamp_cost, expand_rounds)`
    /// (`LXStamper.py:123-144`), which returns the pair. The value is **not** simply `targetCost`:
    /// a random preimage that clears the bar usually clears it by more, and the peering protocol
    /// stores the real value so `peering_key_ready` can compare it against a cost the peer may
    /// later raise (`LXMPeer.py:229-234`).
    ///
    /// Both halves of the returned pair derive from one workblock, so the value can never be
    /// measured against different material than the stamp was found against.
    ///
    /// - Parameter isCancelled: polled between candidate batches. Returns nil when it goes true.
    ///   No production canceller is wired today; single-flight generation is what bounds the cost.
    public static func generateStamp(material: Data,
                                     targetCost: Int,
                                     expandRounds: Int = defaultExpandRounds,
                                     isCancelled: (() -> Bool)? = nil) -> (stamp: Data, value: Int)? {
        let workblock = stampWorkblock(material: material, expandRounds: expandRounds)

        // Parallel search, a deliberate deviation from the reference. Python picks its
        // single-threaded `job_simple` on Darwin (`LXStamper.py:132-136`) because its multi-process
        // path relies on `fork`, not because the algorithm demands one core. The output is a random
        // preimage: which thread found it is wire-invisible, and any found stamp is as good as any
        // other. At the default peering cost of 18 the difference is minutes.
        let cores = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        let found = FoundStamp()

        while found.take() == nil {
            if isCancelled?() == true { return nil }

            DispatchQueue.concurrentPerform(iterations: cores) { _ in
                // A batch, so the found-flag is checked often enough to stop promptly but not so
                // often that the atomic dominates the hashing.
                for _ in 0 ..< 256 {
                    if found.isSet { return }

                    var stamp = Data(count: stampSize)
                    _ = stamp.withUnsafeMutableBytes {
                        SecRandomCopyBytes(kSecRandomDefault, stampSize, $0.baseAddress!)
                    }
                    // Incremental hash: SHA256(workblock || stamp) without allocating the
                    // concatenation — the workblock is up to 750 KB for message stamps.
                    var hasher = SHA256()
                    hasher.update(data: workblock)
                    hasher.update(data: stamp)
                    let digest = Data(hasher.finalize())

                    let value = countLeadingZeroBits(digest)
                    if value >= targetCost {
                        found.set(stamp: stamp, value: value)
                        return
                    }
                }
            }
        }

        return found.take()
    }

    /// First stamp to clear the bar, published to the other search threads.
    private final class FoundStamp {
        private let lock = NSLock()
        private var result: (stamp: Data, value: Int)?
        private var flag = false

        /// Read without the lock so the hot loop's early-out costs nothing. A stale `false` only
        /// means one more candidate is hashed before the batch notices.
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }

        func set(stamp: Data, value: Int) {
            lock.lock(); defer { lock.unlock() }
            guard result == nil else { return }   // first writer wins; the rest are equally valid
            result = (stamp, value)
            flag = true
        }

        func take() -> (stamp: Data, value: Int)? {
            lock.lock(); defer { lock.unlock() }
            return result
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

    /// The material a peering key is computed over: **receiver ‖ sender**, 16 + 16 = 32 bytes.
    ///
    /// Both Python sites agree on that order even though they name the halves differently:
    ///
    /// - the generator (`LXMPeer.py:258`) builds `self.identity.hash + self.router.identity.hash`
    ///   — the *remote peer it is dialling* first, itself second;
    /// - the validator (`LXMRouter.py:2300`) builds `self.identity.hash + remote_identity.hash`
    ///   — *itself* first, the sender second.
    ///
    /// Both are receiver-then-sender. The argument labels here state which is which so the two
    /// call sites cannot silently disagree.
    ///
    /// These are **Identity** hashes — `Identity.truncated_hash(public_key)`, 16 bytes
    /// (`RNS/Identity.py:784`) — not destination hashes. An `LXMPeer` is keyed by its *propagation
    /// destination* hash, so the identity must be recalled from the transport first.
    public static func peeringID(receiverIdentityHash: Data, senderIdentityHash: Data) -> Data {
        receiverIdentityHash + senderIdentityHash
    }

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
