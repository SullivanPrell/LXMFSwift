import Foundation

/// Values captured from the Python reference implementation, not computed by this package.
///
/// Everything else in this suite checks Swift against Swift. The peering workblock is a 25-round
/// HKDF-SHA256 expansion salted with `msgpack.packb(n)` per round; if Swift's expansion diverges
/// from Python's by one round, one salt byte or one HKDF parameter, both the generator and the
/// validator in this package move together and every Swift-only test still passes. On the wire it
/// surfaces as `ERROR_INVALID_KEY` (0xF3) from the peer — with **nothing the sender can log**,
/// because the sender's own validation of its own key succeeds.
///
/// Captured 2026-07-31 from `tri-test/.venv` (LXMF 1.1.0, RNS 1.4.2):
///
/// ```python
/// import LXMF.LXStamper as S, hashlib
/// m  = bytes(range(16)) * 2
/// wb = S.stamp_workblock(m, expand_rounds=S.WORKBLOCK_EXPAND_ROUNDS_PEERING)
/// k, v = S.generate_stamp(m, 4, expand_rounds=S.WORKBLOCK_EXPAND_ROUNDS_PEERING)
/// print(len(wb), hashlib.sha256(wb).hexdigest(), k.hex(), v, S.validate_peering_key(m, k, 4))
/// ```
enum PythonPeeringVectors {

    /// The peering material: a 16-byte receiver identity hash followed by a 16-byte sender's.
    /// `bytes(range(16)) * 2` — deliberately two identical halves, so a test that swapped the
    /// operands would still pass here. Operand *order* is pinned separately, against real
    /// identities, by `testPeeringIDIsReceiverThenSenderAndIs32Bytes`.
    static let peeringID = Data([
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    ])

    /// A peering key Python generated over `peeringID` at cost 4, and accepts via
    /// `validate_peering_key`.
    static let key = Data([
        0x8e, 0x72, 0x88, 0xe0, 0xfb, 0x68, 0x39, 0x3d,
        0x5c, 0x52, 0xbf, 0x12, 0xa2, 0x4b, 0xbd, 0xd0,
        0x9a, 0xf7, 0x48, 0xa1, 0xd8, 0xe4, 0x27, 0xec,
        0x81, 0x09, 0x0a, 0x12, 0xed, 0xfc, 0x52, 0x18,
    ])

    static let cost  = 4
    static let value = 4

    /// `WORKBLOCK_EXPAND_ROUNDS_PEERING` × 256 bytes.
    static let workblockLength = 6400

    /// SHA-256 of the whole 6400-byte workblock. This is the single assertion in the package that
    /// can catch an expand-rounds, HKDF or msgpack-salt divergence from the reference.
    static let workblockDigest = Data([
        0xee, 0x18, 0x4e, 0xf3, 0xdc, 0x25, 0x29, 0xea,
        0x15, 0xd6, 0x35, 0x19, 0x27, 0x49, 0xfb, 0x7d,
        0x52, 0x24, 0xfd, 0xef, 0xae, 0x64, 0x4d, 0xf6,
        0xa7, 0x92, 0x4a, 0x01, 0xce, 0xef, 0x68, 0xec,
    ])

    /// `msgpack.packb([peering_key, [tid_a1, tid_a2]])` — the exact offer-request payload a Python
    /// propagation node emits (`LXMPeer.py:385`), with `key` above and two 32-byte transient IDs.
    static let offerPayload = Data(hex:
        "92c4208e7288e0fb68393d5c52bf12a24bbdd09af748a1d8e427ec81090a12edfc5218" +
        "92c420a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1" +
        "c420a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2")!

    static let offerTransientIDs = [Data(repeating: 0xa1, count: 32),
                                    Data(repeating: 0xa2, count: 32)]

    /// `msgpack.packb([1234567890.5, [b"\xde\xad\xbe\xef", b"\xca\xfe"]])` — the sync resource
    /// payload shape (`LXMPeer.py:466`): a float timestamp then a list of whole message files.
    static let resourcePayload = Data(hex: "92cb41d26580b4a0000092c404deadbeefc402cafe")!

    static let resourceTimestamp = 1234567890.5
    static let resourceBodies    = [Data([0xde, 0xad, 0xbe, 0xef]), Data([0xca, 0xfe])]

    /// Every `LXMPeer.ERROR_*` as Python's umsgpack writes it. All eight are above 127, so all
    /// eight are `uint8` (`0xCC`) — none of them is a msgpack `int`.
    static let errorCodeWireForms: [(name: String, code: UInt8, wire: Data)] = [
        ("ERROR_NO_IDENTITY",   0xF0, Data([0xCC, 0xF0])),
        ("ERROR_NO_ACCESS",     0xF1, Data([0xCC, 0xF1])),
        ("ERROR_INVALID_KEY",   0xF3, Data([0xCC, 0xF3])),
        ("ERROR_INVALID_DATA",  0xF4, Data([0xCC, 0xF4])),
        ("ERROR_INVALID_STAMP", 0xF5, Data([0xCC, 0xF5])),
        ("ERROR_THROTTLED",     0xF6, Data([0xCC, 0xF6])),
        ("ERROR_NOT_FOUND",     0xFD, Data([0xCC, 0xFD])),
        ("ERROR_TIMEOUT",       0xFE, Data([0xCC, 0xFE])),
    ]
}
