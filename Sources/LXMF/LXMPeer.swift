import Foundation
import ReticulumSwift

// MARK: - Propagation entry

/// A single stored message in the propagation node's message store.
/// Mirrors Python's `propagation_entries` list format (index 0–6).
public struct PropagationEntry {
    /// [0] Destination hash (16 bytes) the message is addressed to.
    public let destinationHash: Data
    /// [1] Absolute path to the message file on disk.
    public let filePath: String
    /// [2] Unix timestamp when the message was received.
    public let received: TimeInterval
    /// [3] Size of the file in bytes.
    public var msgSize: Int
    /// [4] Peer destination hashes that have already received this message.
    public var handledPeers: [Data]
    /// [5] Peer destination hashes that still need to receive this message.
    public var unhandledPeers: [Data]
    /// [6] Proof-of-work stamp value for this message.
    public let stampValue: Int

    public init(destinationHash: Data, filePath: String, received: TimeInterval,
                msgSize: Int, handledPeers: [Data] = [], unhandledPeers: [Data] = [],
                stampValue: Int = 0) {
        self.destinationHash  = destinationHash
        self.filePath         = filePath
        self.received         = received
        self.msgSize          = msgSize
        self.handledPeers     = handledPeers
        self.unhandledPeers   = unhandledPeers
        self.stampValue       = stampValue
    }
}

// MARK: - LXMPeer state

/// Sync state of a propagation peer link.
/// Mirrors Python's `LXMPeer` state constants.
public enum LXMPeerState: UInt8, Equatable {
    case idle                 = 0x00
    case linkEstablishing     = 0x01
    case linkReady            = 0x02
    case requestSent          = 0x03
    case responseReceived     = 0x04
    case resourceTransferring = 0x05
}

/// Error codes used in peer sync responses.
/// Mirrors Python's `LXMPeer.ERROR_*` constants.
public enum LXMPeerError: UInt8, Equatable {
    case noIdentity   = 0xF0
    case noAccess     = 0xF1
    case invalidKey   = 0xF3
    case invalidData  = 0xF4
    case invalidStamp = 0xF5
    case throttled    = 0xF6
    case notFound     = 0xFD
    case timeout      = 0xFE
}

extension LXMPeerError {
    /// The peer error this msgpack value carries, or nil if it carries something else.
    ///
    /// **The one place** a wire scalar becomes an error code. Both the peer sync path and the
    /// client download path ask this question; when they each answered it themselves they drifted,
    /// and `bugs/053` is what that cost.
    ///
    /// Read numerically, because the wire form varies with magnitude and encoder: every LXMF error
    /// code is above 127, so umsgpack and this package's own encoder both emit a `uint8` (`0xCC`)
    /// which decodes to `.uint` (`MsgPack.swift:212`), while a value built in memory stays `.int`.
    /// A `switch` tests the enum case, not the number, so matching one case misses the other.
    init?(msgPack value: MsgPack.Value) {
        let scalar: UInt64
        switch value {
        case .uint(let n): scalar = n
        case .int(let n):  guard n >= 0 else { return nil }; scalar = UInt64(n)
        default:           return nil
        }
        guard scalar <= UInt64(UInt8.max) else { return nil }
        self.init(rawValue: UInt8(scalar))
    }
}

/// Peer sync strategy — lazy (on-demand) or persistent (continuous).
/// Mirrors Python's `LXMPeer.STRATEGY_*` constants.
public enum LXMSyncStrategy: Int, Equatable {
    case lazy       = 0x01
    case persistent = 0x02
}

// MARK: - LXMPeer

/// Represents a remote LXMF propagation node that this node is peered with.
/// Manages the sync state machine: establish link → offer messages → transfer.
///
/// Mirrors Python's `LXMPeer` class in `LXMPeer.py`.
public final class LXMPeer {

    // MARK: - Constants

    /// RNS request path for the peer-to-peer sync offer.
    /// Python: `LXMPeer.OFFER_REQUEST_PATH = "/offer"`.
    public static let offerRequestPath   = "/offer"

    /// RNS request path for client message download.
    /// Python: `LXMPeer.MESSAGE_GET_PATH = "/get"`.
    public static let messageGetPath     = "/get"

    /// Maximum time (seconds) a peer can be unreachable before it is dropped.
    /// Python: `LXMPeer.MAX_UNREACHABLE = 14*24*60*60`.
    public static let maxUnreachable: TimeInterval = 14 * 24 * 60 * 60

    /// Backoff step added to the next sync attempt on each consecutive failure.
    /// Python: `LXMPeer.SYNC_BACKOFF_STEP = 12*60`.
    public static let syncBackoffStep: TimeInterval = 12 * 60

    /// Grace period (seconds) to wait for path request answer before deferring.
    /// Python: `LXMPeer.PATH_REQUEST_GRACE = 7.5`.
    public static let pathRequestGrace: TimeInterval = 7.5

    /// Default sync strategy.
    /// Python: `LXMPeer.DEFAULT_SYNC_STRATEGY = STRATEGY_PERSISTENT`.
    public static let defaultSyncStrategy: LXMSyncStrategy = .persistent

    // MARK: - Identity

    /// Destination hash (16 bytes) of the remote propagation node.
    public let destinationHash: Data

    /// Current state of the sync link to this peer.
    public var state: LXMPeerState = .idle

    // MARK: - Strategy

    /// Whether to use lazy (on-demand) or persistent (continuous) sync.
    public var syncStrategy: LXMSyncStrategy

    // MARK: - Liveness

    /// Whether this peer is considered reachable.
    public var alive: Bool = false

    /// Unix timestamp when we last received a successful sync from this peer.
    public var lastHeard: TimeInterval = 0

    // MARK: - Timing

    /// Unix timestamp of the next allowed sync attempt.
    public var nextSyncAttempt: TimeInterval = 0

    /// Unix timestamp of the last sync attempt.
    public var lastSyncAttempt: TimeInterval = 0

    /// Current accumulated backoff for consecutive sync failures.
    public var syncBackoff: TimeInterval = 0

    /// Timebase of the remote peer node.
    public var peeringTimebase: TimeInterval = 0

    // MARK: - Rate tracking

    /// Most recent measured link establishment rate (bits/s).
    public var linkEstablishmentRate: Double = 0

    /// Most recent measured sync transfer rate (bits/s).
    public var syncTransferRate: Double = 0

    // MARK: - Negotiated limits (learned from peer announces)

    /// Per-transfer limit for outgoing messages to this peer, in KB. nil = unlimited.
    public var propagationTransferLimit: Double? = nil

    /// Per-sync limit for total data transferred to this peer, in KB. nil = unlimited.
    public var propagationSyncLimit: Double? = nil

    /// Stamp cost this peer requires for messages it will accept.
    public var propagationStampCost: Int? = nil

    /// Flexibility (±) on the peer's stamp cost requirement.
    public var propagationStampCostFlexibility: Int? = nil

    /// PoW cost required for peering with this peer.
    public var peeringCost: Int? = nil

    // MARK: - Peering key

    /// Proof-of-work peering key for this peer: the 32-byte stamp and the value it reached.
    ///
    /// `private(set)`: `generatePeeringKey()` and `peeringKeyReady()` are the only writers.
    /// While this was settable from outside, tests assigned `(stamp, 0)` by hand and asserted the
    /// method they had just fed — which is how "no writer exists anywhere in `Sources/`" stayed
    /// invisible from 2026-06-23 to 2026-07-31 (`swift_devel/bugs/054`).
    public private(set) var peeringKey: (stamp: Data, value: Int)? = nil

    /// The value of the peering key we hold, or nil if we hold none.
    /// Python: `LXMPeer.peering_key_value()` (`LXMPeer.py:238-240`).
    public var peeringKeyValue: Int? {
        peerLock.lock(); defer { peerLock.unlock() }
        return peeringKey?.value
    }

    /// How many key generations this peer has started. Single-flight is otherwise unobservable:
    /// eight redundant generations and one produce the same key.
    public private(set) var peeringKeyGenerationsStarted: Int = 0

    /// Set while a generation is in flight, so concurrent sync passes do not each start one.
    private var peeringKeyGenerating = false

    /// Proof of work runs here, never on the job thread.
    private let peeringKeyQueue = DispatchQueue(label: "lxmf.peer.peeringkey", qos: .utility)

    // MARK: - Metadata

    /// Peer metadata dict (from announce app data).
    public var metadata: [String: String]? = nil

    // MARK: - Statistics

    /// Count of messages we have offered to this peer.
    public var offered: Int = 0

    /// Count of messages we have successfully transferred to this peer.
    public var outgoing: Int = 0

    /// Count of messages received from this peer.
    public var incoming: Int = 0

    /// Bytes received from this peer.
    public var rxBytes: Int = 0

    /// Bytes sent to this peer.
    public var txBytes: Int = 0

    // MARK: - Sync state

    /// Active link to this peer (nil when not syncing).
    public var link: Link? = nil

    /// The transient IDs included in the most recent sync offer we sent.
    public var lastOffer: [Data] = []

    /// Transient IDs currently being transferred (non-nil during active resource transfer).
    public var currentlyTransferringMessages: [Data]? = nil

    /// Whether this sync link has already been re-identified after an `ERROR_NO_IDENTITY`.
    /// Reset when a link is created; see the `.noIdentity` branch of `offerResponse`.
    private var hasReIdentifiedOnThisLink = false

    /// When the in-flight resource transfer started, for the rate measurement.
    /// Python never initialises this attribute; it appears first at `LXMPeer.py:470` and is read
    /// under a `!= None` guard at `:509`.
    private var currentSyncTransferStarted: TimeInterval? = nil

    /// The active sync link, for tests that must assert it was released.
    ///
    /// `@testable`-only. The link itself is not exposed publicly: a test that could set it could
    /// fake having established one, which is the shape of defect this whole change exists to
    /// close.
    var linkForTesting: Link? {
        peerLock.lock(); defer { peerLock.unlock() }
        return link
    }

    // MARK: - Batched queue

    private var handledMessagesQueue:   [Data] = []
    private var unhandledMessagesQueue: [Data] = []

    // MARK: - Count cache

    private var _hmCount: Int = 0
    private var _umCount: Int = 0
    private var _hmCountsSynced: Bool = false
    private var _umCountsSynced: Bool = false

    // MARK: - Synchronization
    //
    // Guards this peer's OWN mutable internal state — the batched message queues
    // (`handledMessagesQueue` / `unhandledMessagesQueue`), the count caches
    // (`_hmCount` / `_umCount` / `_hmCountsSynced` / `_umCountsSynced`), and the sync
    // state machine (`state` / `link` / `nextSyncAttempt` / `lastSyncAttempt` /
    // `syncBackoff` / `currentlyTransferringMessages` / `lastOffer` / `alive` /
    // `lastHeard` / `offered` / `outgoing` / `txBytes`). The router drives these from
    // its PN methods (flush / sync / addPeer / savePeers) which — post the router-side
    // hardening — run OUTSIDE the router lock, so two threads can enter the same peer's
    // `processQueues()` / `sync()` / `toBytes()` concurrently.
    //
    // Discipline: `peerLock` only ever guards short, callout-free critical sections. It
    // is NEVER held across a call into the router (the `peer*` accessors take the router
    // lock) or across a link callout — such calls are made on snapshots taken under the
    // lock, with results committed under the lock afterwards (snapshot-under-lock /
    // act-outside / commit-under-lock). Consequently `peerLock` and the router `lock`
    // are never held simultaneously in either direction, so no lock-order inversion is
    // possible. `NSLock` is not reentrant, so no peer method holding `peerLock` may call
    // another peer method that reacquires it.
    private let peerLock = NSLock()

    // MARK: - Back-reference to router

    weak var router: LXMRouter?

    // MARK: - Init

    public init(router: LXMRouter, destinationHash: Data,
                syncStrategy: LXMSyncStrategy = LXMPeer.defaultSyncStrategy) {
        self.router          = router
        self.destinationHash = destinationHash
        self.syncStrategy    = syncStrategy
    }

    // MARK: - Serialization

    /// Deserialize a peer from msgpack bytes.
    /// Mirrors Python's `LXMPeer.from_bytes(peer_bytes, router)`.
    public static func from(bytes: Data, router: LXMRouter) -> LXMPeer? {
        guard case .map(let pairs) = try? MsgPack.decode(bytes) else { return nil }
        // Build a lookup dict from key string → Value
        var dict: [String: MsgPack.Value] = [:]
        for (k, v) in pairs {
            if case .string(let s) = k { dict[s] = v }
        }

        guard case .bytes(let dhData) = dict["destination_hash"] else { return nil }
        let destinationHash = Data(dhData)

        // Helper: extract Int from .int or .uint
        func intVal(_ key: String) -> Int? {
            switch dict[key] {
            case .int(let n)?:  return Int(n)
            case .uint(let n)?: return Int(n)
            default:            return nil
            }
        }
        // Helper: extract Double (or Int coerced to Double)
        func dblVal(_ key: String) -> Double? {
            switch dict[key] {
            case .double(let v)?: return v
            case .int(let n)?:    return Double(n)
            case .uint(let n)?:   return Double(n)
            default:              return nil
            }
        }

        let strategy: LXMSyncStrategy
        if let ss = intVal("sync_strategy") {
            strategy = LXMSyncStrategy(rawValue: ss) ?? .persistent
        } else {
            strategy = .persistent
        }

        let peer = LXMPeer(router: router, destinationHash: destinationHash,
                           syncStrategy: strategy)

        if let v = dblVal("peering_timebase")         { peer.peeringTimebase = v }
        if case .bool(let v) = dict["alive"]           { peer.alive = v }
        if let v = dblVal("last_heard")               { peer.lastHeard = v }
        if let v = dblVal("last_sync_attempt")        { peer.lastSyncAttempt = v }
        if let v = intVal("offered")                  { peer.offered = v }
        if let v = intVal("outgoing")                 { peer.outgoing = v }
        if let v = intVal("incoming")                 { peer.incoming = v }
        if let v = intVal("rx_bytes")                 { peer.rxBytes = v }
        if let v = intVal("tx_bytes")                 { peer.txBytes = v }
        if let v = dblVal("link_establishment_rate")  { peer.linkEstablishmentRate = v }
        if let v = dblVal("sync_transfer_rate")       { peer.syncTransferRate = v }

        // Nullable doubles
        if let v = dblVal("propagation_transfer_limit") { peer.propagationTransferLimit = v }
        if let v = dblVal("propagation_sync_limit")     { peer.propagationSyncLimit = v }

        // Nullable ints
        if let v = intVal("propagation_stamp_cost")              { peer.propagationStampCost = v }
        if let v = intVal("propagation_stamp_cost_flexibility")  { peer.propagationStampCostFlexibility = v }
        if let v = intVal("peering_cost")                        { peer.peeringCost = v }

        // Handled and unhandled IDs — only add if still in router's propagation_entries
        if case .array(let handledArr) = dict["handled_ids"] {
            for item in handledArr {
                if case .bytes(let tid) = item {
                    let transientID = Data(tid)
                    if router.peerEntryExists(transientID) {
                        peer.addHandledMessage(transientID)
                    }
                }
            }
        }
        if case .array(let unhandledArr) = dict["unhandled_ids"] {
            for item in unhandledArr {
                if case .bytes(let tid) = item {
                    let transientID = Data(tid)
                    if router.peerEntryExists(transientID) {
                        peer.addUnhandledMessage(transientID)
                    }
                }
            }
        }

        return peer
    }

    /// Serialize this peer to msgpack bytes.
    /// Mirrors Python's `LXMPeer.to_bytes()`.
    public func toBytes() -> Data {
        var pairs: [(MsgPack.Value, MsgPack.Value)] = []

        func kv(_ key: String, _ val: MsgPack.Value) {
            pairs.append((.string(key), val))
        }

        // Snapshot the lock-guarded scalars (concurrent sync()/resourceConcluded() may
        // write them). `incoming`/`rxBytes` have no runtime writer, so they are read
        // directly; `handledMessages`/`unhandledMessages` self-lock, so they run below.
        peerLock.lock()
        let sAlive           = alive
        let sLastHeard       = lastHeard
        let sLastSyncAttempt = lastSyncAttempt
        let sOffered         = offered
        let sOutgoing        = outgoing
        let sTxBytes         = txBytes
        peerLock.unlock()

        kv("destination_hash",       .bytes(destinationHash))
        kv("peering_timebase",       .double(peeringTimebase))
        kv("alive",                  .bool(sAlive))
        kv("last_heard",             .double(sLastHeard))
        kv("sync_strategy",          .int(Int64(syncStrategy.rawValue)))
        kv("last_sync_attempt",      .double(sLastSyncAttempt))
        kv("offered",                .int(Int64(sOffered)))
        kv("outgoing",               .int(Int64(sOutgoing)))
        kv("incoming",               .int(Int64(incoming)))
        kv("rx_bytes",               .int(Int64(rxBytes)))
        kv("tx_bytes",               .int(Int64(sTxBytes)))
        kv("link_establishment_rate",.double(linkEstablishmentRate))
        kv("sync_transfer_rate",     .double(syncTransferRate))

        if let v = propagationTransferLimit { kv("propagation_transfer_limit", .double(v)) }
        else { kv("propagation_transfer_limit", .nil) }
        if let v = propagationSyncLimit     { kv("propagation_sync_limit", .double(v)) }
        else { kv("propagation_sync_limit", .nil) }
        if let v = propagationStampCost     { kv("propagation_stamp_cost", .int(Int64(v))) }
        else { kv("propagation_stamp_cost", .nil) }
        if let v = propagationStampCostFlexibility {
            kv("propagation_stamp_cost_flexibility", .int(Int64(v)))
        } else { kv("propagation_stamp_cost_flexibility", .nil) }
        if let v = peeringCost { kv("peering_cost", .int(Int64(v))) }
        else { kv("peering_cost", .nil) }

        // Handled IDs = propagation_entries entries where our destinationHash is in handledPeers
        let handledIDs = handledMessages.map { MsgPack.Value.bytes($0) }
        let unhandledIDs = unhandledMessages.map { MsgPack.Value.bytes($0) }
        kv("handled_ids",   .array(handledIDs))
        kv("unhandled_ids", .array(unhandledIDs))

        return MsgPack.encode(.map(pairs))
    }

    // MARK: - Computed message sets

    /// All transient IDs for messages this peer has already received.
    /// Python: `LXMPeer.handled_messages` property.
    public var handledMessages: [Data] {
        guard let router else { return [] }
        // Query the router WITHOUT `peerLock` (the accessor takes the router lock);
        // then take `peerLock` only to refresh the cache.
        let result = router.peerHandledTransientIDs(for: destinationHash)
        peerLock.lock()
        _hmCount = result.count
        _hmCountsSynced = true
        peerLock.unlock()
        return result
    }

    /// All transient IDs for messages this peer has NOT yet received.
    /// Python: `LXMPeer.unhandled_messages` property.
    public var unhandledMessages: [Data] {
        guard let router else { return [] }
        let result = router.peerUnhandledTransientIDs(for: destinationHash)
        peerLock.lock()
        _umCount = result.count
        _umCountsSynced = true
        peerLock.unlock()
        return result
    }

    /// Cached handled message count (may be stale; refresh via `handledMessages`).
    public var handledMessageCount: Int {
        peerLock.lock(); let synced = _hmCountsSynced; peerLock.unlock()
        if !synced { _ = handledMessages }   // refreshes cache (self-locks)
        peerLock.lock(); defer { peerLock.unlock() }
        return _hmCount
    }

    /// Cached unhandled message count (may be stale; refresh via `unhandledMessages`).
    public var unhandledMessageCount: Int {
        peerLock.lock(); let synced = _umCountsSynced; peerLock.unlock()
        if !synced { _ = unhandledMessages }   // refreshes cache (self-locks)
        peerLock.lock(); defer { peerLock.unlock() }
        return _umCount
    }

    /// Acceptance rate (outgoing / offered). 0.0 when offered == 0.
    public var acceptanceRate: Double {
        peerLock.lock(); let o = offered, g = outgoing; peerLock.unlock()
        return o == 0 ? 0.0 : Double(g) / Double(o)
    }

    // MARK: - Message tracking (direct mutations on propagation_entries)

    /// Mark message as handled by this peer (i.e., peer already has it).
    /// Python: `LXMPeer.add_handled_message(transient_id)`.
    public func addHandledMessage(_ transientID: Data) {
        guard let router else { return }
        // Router accessor first (takes the router lock); then `peerLock` for the cache.
        if router.peerAddHandled(transientID, destinationHash: destinationHash) {
            peerLock.lock(); _hmCountsSynced = false; peerLock.unlock()
        }
    }

    /// Mark message as needing to be sent to this peer.
    /// Python: `LXMPeer.add_unhandled_message(transient_id)`.
    public func addUnhandledMessage(_ transientID: Data) {
        guard let router else { return }
        if router.peerAddUnhandled(transientID, destinationHash: destinationHash) {
            peerLock.lock(); _umCount += 1; peerLock.unlock()
        }
    }

    /// Remove message from the handled set.
    /// Python: `LXMPeer.remove_handled_message(transient_id)`.
    public func removeHandledMessage(_ transientID: Data) {
        guard let router else { return }
        if router.peerRemoveHandled(transientID, destinationHash: destinationHash) {
            peerLock.lock(); _hmCountsSynced = false; peerLock.unlock()
        }
    }

    /// Remove message from the unhandled set.
    /// Python: `LXMPeer.remove_unhandled_message(transient_id)`.
    public func removeUnhandledMessage(_ transientID: Data) {
        guard let router else { return }
        if router.peerRemoveUnhandled(transientID, destinationHash: destinationHash) {
            peerLock.lock(); _umCountsSynced = false; peerLock.unlock()
        }
    }

    // MARK: - Batched queue

    /// Queue a message as unhandled (processed later by `processQueues()`).
    public func queueUnhandledMessage(_ transientID: Data) {
        peerLock.lock(); unhandledMessagesQueue.append(transientID); peerLock.unlock()
    }

    /// Queue a message as handled (processed later by `processQueues()`).
    public func queueHandledMessage(_ transientID: Data) {
        peerLock.lock(); handledMessagesQueue.append(transientID); peerLock.unlock()
    }

    /// Flush the batched queues into the propagation_entries.
    /// Python: `LXMPeer.process_queues()`.
    ///
    /// Each queue element is popped under `peerLock` (an atomic check-and-`removeLast`,
    /// so two concurrent flushes cooperatively drain the shared queue instead of both
    /// passing an `!isEmpty` guard and then both calling `removeLast` on an emptied
    /// queue — the crash this hardening fixes). The `handled`/`unhandled` membership
    /// snapshots and the `add`/`remove` calls run OUTSIDE the lock (they self-lock /
    /// route through the router), preserving the original behaviour: membership is
    /// tested against the pre-drain snapshot.
    public func processQueues() {
        peerLock.lock()
        let hasWork = !handledMessagesQueue.isEmpty || !unhandledMessagesQueue.isEmpty
        peerLock.unlock()
        guard hasWork else { return }

        let handled   = handledMessages    // refresh cache (self-locks)
        let unhandled = unhandledMessages

        while true {
            peerLock.lock()
            guard !handledMessagesQueue.isEmpty else { peerLock.unlock(); break }
            let tid = handledMessagesQueue.removeLast()
            peerLock.unlock()
            if !handled.contains(tid) { addHandledMessage(tid) }
            if unhandled.contains(tid) { removeUnhandledMessage(tid) }
        }
        while true {
            peerLock.lock()
            guard !unhandledMessagesQueue.isEmpty else { peerLock.unlock(); break }
            let tid = unhandledMessagesQueue.removeLast()
            peerLock.unlock()
            if !handled.contains(tid) && !unhandled.contains(tid) {
                addUnhandledMessage(tid)
            }
        }
    }

    /// Whether there are queued items awaiting processing.
    public var hasQueuedItems: Bool {
        peerLock.lock(); defer { peerLock.unlock() }
        return !handledMessagesQueue.isEmpty || !unhandledMessagesQueue.isEmpty
    }

    // MARK: - Peering key generation

    /// Whether the key we hold satisfies the cost this peer currently demands.
    ///
    /// Exact port of `LXMPeer.peering_key_ready()` (`LXMPeer.py:227-236`), including two things
    /// the inline check this replaces got wrong:
    ///
    /// - **A cost of 0 is never ready.** Python's `if not self.peering_cost: return False` is a
    ///   falsy test and `0` is falsy, so a peer advertising cost 0 can never be synced to. That
    ///   reads as a bug and is not one: it is Python-to-Python behaviour, already documented at
    ///   `LXMRouter.swift:423-426`, and a Swift node that treated 0 as "free" would sync to peers
    ///   a Python node in the same mesh silently skips.
    /// - **A key worth less than the cost is discarded, not merely rejected** (`:233-234`). A peer
    ///   may raise its cost at any announce; without the reset we would re-offer the same
    ///   too-cheap key on every pass and be refused with `ERROR_INVALID_KEY` forever.
    ///
    /// Takes `peerLock` — never call it with the lock held.
    private func peeringKeyReady() -> Bool {
        peerLock.lock(); defer { peerLock.unlock() }
        guard let cost = peeringCost, cost > 0 else { return false }
        guard let key = peeringKey else { return false }
        if key.value >= cost { return true }
        peeringKey = nil
        return false
    }

    /// Generate this peer's peering key, if it does not already have a satisfying one.
    ///
    /// Port of `LXMPeer.generate_peering_key()` (`LXMPeer.py:242-265`). Returns whether a usable
    /// key is in place when it returns.
    ///
    /// **Single-flight**, a deliberate deviation from the reference: Python starts a fresh daemon
    /// thread from every postponed sync pass (`:285-286`), all of which serialise on
    /// `_peering_key_lock` through a proof of work that takes seconds at the default cost of 18 —
    /// the job loop can queue them faster than they retire. Here the second and later callers see
    /// the in-flight flag and return immediately.
    ///
    /// The proof of work runs with `peerLock` **released**. Identities come from the context, so
    /// this is also the point at which an unrecallable peer identity stops the attempt — Python
    /// re-recalls here and logs (`:252-256`).
    @discardableResult
    func generatePeeringKey() -> Bool {
        peerLock.lock()
        guard let cost = peeringCost, cost > 0 else { peerLock.unlock(); return false }
        // Any existing key is accepted here, exactly as Python does (`:245`) — **not**
        // `key.value >= cost`. Deciding a key's sufficiency is `peeringKeyReady()`'s job, and it
        // discards one that has fallen short. Re-deciding it here would make that discard dead
        // code, and dead code is how the reset stops being tested.
        if peeringKey != nil { peerLock.unlock(); return true }
        guard !peeringKeyGenerating else { peerLock.unlock(); return false }
        peeringKeyGenerating = true
        peeringKeyGenerationsStarted += 1
        peerLock.unlock()

        defer { peerLock.lock(); peeringKeyGenerating = false; peerLock.unlock() }

        guard let ctx = router?.makePeerSyncContext(for: self) else { return false }

        // receiver ‖ sender — the peer we are dialling first, ourselves second (`:258`).
        let material = LXStamper.peeringID(receiverIdentityHash: ctx.peerIdentity.hash,
                                           senderIdentityHash: ctx.routerIdentity.hash)
        guard let generated = LXStamper.generateStamp(material: material, targetCost: cost,
                                                      expandRounds: LXStamper.peeringExpandRounds)
        else { return false }

        guard generated.value >= cost else { return false }   // `:260-261`
        peerLock.lock()
        peeringKey = generated
        peerLock.unlock()
        return true
    }

    // MARK: - Sync

    /// Attempt a sync with this peer.
    /// Mirrors Python's `LXMPeer.sync()`.
    /// In production this would establish an RNS Link; here we expose
    /// the decision logic as testable state changes.
    public func sync() {
        let now = Date().timeIntervalSince1970

        // Announce-negotiated fields have no concurrent writer — read them outside the lock.
        let stampCostsKnown = propagationStampCost != nil
                           && propagationStampCostFlexibility != nil
                           && peeringCost != nil
        let keyReady = peeringKeyReady()   // self-locks; may discard a now-too-cheap key

        peerLock.lock()
        lastSyncAttempt = now
        let syncTimeReached = now > nextSyncAttempt
        let syncChecks = syncTimeReached && stampCostsKnown && keyReady
        guard syncChecks else {
            // Postpone; if time has passed but last attempt > last_heard, mark not alive
            if !syncTimeReached && now > lastHeard { alive = false }
            peerLock.unlock()

            // The branch that was missing entirely: without a key nothing downstream can ever
            // run, so the postponement has to be the thing that starts making one (`:283-286`).
            if syncTimeReached && stampCostsKnown && !keyReady {
                peeringKeyQueue.async { [weak self] in self?.generatePeeringKey() }
            }
            return
        }
        peerLock.unlock()

        // Everything past this point needs the outside world (`:304-309`, `:392-393`).
        guard let ctx = router?.makePeerSyncContext(for: self) else { return }

        // The path gate, and the reason the backoff bump is *below* it (`:295-301` vs `:321`):
        // waiting for a path answer is not a failed sync, and charging it 12 minutes of backoff
        // would punish a peer for the network being slow to answer.
        //
        // Python sleeps `PATH_REQUEST_GRACE` (7.5 s) here and re-checks. That is dropped: it would
        // block the whole LXMF job loop, whose tick is 4 s (`LXMRouter.swift:414`), and the
        // `syncPeers` cadence of 24 s already exceeds the grace it was buying. Strictly slower to
        // notice a new path, never wrong. `LXMPeer.pathRequestGrace` documents the constant this
        // deliberately does not use.
        guard ctx.transport.hasPath(to: destinationHash) else {
            try? ctx.transport.requestPath(for: destinationHash)
            return
        }

        // `unhandledMessageCount` self-locks (and routes through the router), so read it
        // WITHOUT `peerLock` held. Guard order is preserved: unhandled>0, then
        // currentlyTransferring==nil, then the state dispatch.
        guard unhandledMessageCount > 0 else { return }  // nothing to send

        peerLock.lock()
        // A transfer already in flight; a second offer would race its index (`:315-317`).
        guard currentlyTransferringMessages == nil else { peerLock.unlock(); return }
        let currentState = state

        switch currentState {
        case .idle:
            // ---- ORDERING A: commit every field a callback can read, *then* dial. ----
            //
            // Over a synchronous transport `Link.initiate` and the `onEstablished` assignment
            // below can run the entire machine — identify, offer, response, resource, teardown —
            // before either returns. A `state = …` written after one of them stomps a later
            // transition, and `syncPeers` only ever selects `.idle` (`LXMRouter.swift:3038`), so
            // the peer is then never dialled again. There must be no state write after the
            // callouts in this branch.
            syncBackoff += LXMPeer.syncBackoffStep
            nextSyncAttempt = now + syncBackoff
            state = .linkEstablishing
            peerLock.unlock()

            guard let link = try? Link.initiate(destination: ctx.destination,
                                                transport: ctx.transport) else {
                peerLock.lock(); state = .idle; peerLock.unlock()
                return
            }

            peerLock.lock()
            self.link = link
            hasReIdentifiedOnThisLink = false
            peerLock.unlock()

            // `onClosed` first: `onEstablished` has a replaying `didSet` (`Link.swift:326-329`)
            // and can drive straight through to a teardown, and an `onClosed` not yet installed
            // would lose the reset to `.idle`. `onClosed` itself has no replay (`:330`), hence
            // the explicit check afterwards.
            link.onClosed      = { [weak self] closed in self?.syncLinkClosed(closed) }
            link.onEstablished = { [weak self] up in self?.syncLinkEstablished(up, ctx) }
            if link.status == .closed || link.status == .failed { syncLinkClosed(link) }

        case .linkReady:
            let established = link
            peerLock.unlock()
            guard established != nil else { return }
            sendOffer(ctx)

        default:
            // Mid-sync. Python falls through the `LINK_READY` test to nothing (`:326`).
            peerLock.unlock()
        }
    }

    // MARK: - Link lifecycle

    /// The sync link came up: identify, record the rate, and re-enter the pump.
    /// Port of `LXMPeer.link_established(link)` (`LXMPeer.py:534-542`).
    private func syncLinkEstablished(_ link: Link, _ ctx: PeerSyncContext) {
        // Mandatory. The peer keys both its peering-key check and its throttle off the remote
        // identity, and answers an unidentified link with `ERROR_NO_IDENTITY`
        // (`LXMRouter.swift:3110`) — so without this nothing ever transfers.
        try? link.identify(as: ctx.routerIdentity)

        if let rate = link.getEstablishmentRate() {   // already bits/s (`Link.swift:1229`)
            peerLock.lock(); linkEstablishmentRate = rate; peerLock.unlock()
        }

        peerLock.lock()
        state = .linkReady
        // Required, not cosmetic: the re-entrant `sync()` below re-evaluates `now >
        // nextSyncAttempt`, and the `.idle` branch has just pushed that a backoff step into the
        // future. Without the reset the pump fails its own gate and the link idles until the
        // reaper collects it (`:541`).
        nextSyncAttempt = 0
        peerLock.unlock()

        sync()   // `:542` — re-entry 1
    }

    /// The sync link went away, for any reason. Port of `LXMPeer.link_closed` (`:544-546`).
    private func syncLinkClosed(_ link: Link) {
        peerLock.lock()
        self.link = nil
        state = .idle
        peerLock.unlock()
    }

    /// Tear down a sync link that has gone quiet, and release the peer.
    ///
    /// Called only from `LXMRouter.cleanLinks()`. A peer's own sync link is in neither
    /// `directLinks` nor `activePropagationLinks`, so nothing else collects it — and Python
    /// leaves these to the RNS watchdog. It covers the four stalls that otherwise wedge a peer
    /// out of `syncPeers` selection forever: `.linkReady` after an offer that had nothing left to
    /// send (`:381-383`), `.responseReceived` after `ERROR_NO_ACCESS` (`:419`) or
    /// `ERROR_THROTTLED` (`:425`), and `.requestSent` after a send that failed.
    func reapStalledSyncLink(maxInactivity: TimeInterval) {
        peerLock.lock()
        let current = link
        let isStalled = current != nil && state != .idle
        peerLock.unlock()

        guard isStalled, let current, current.noDataFor() > maxInactivity else { return }
        try? current.teardown()            // callout — may re-enter syncLinkClosed
        peerLock.lock()
        link = nil
        state = .idle
        peerLock.unlock()
    }

    // MARK: - The offer

    /// Choose what to offer this peer, applying its advertised limits.
    ///
    /// Port of the `LINK_READY` branch of `LXMPeer.sync()` (`LXMPeer.py:327-388`). Returns `nil`
    /// when nothing survives — Python returns there with the link still open and `state` still
    /// `LINK_READY` (`:381-383`), and so does this; `reapStalledSyncLink` is what rescues it.
    private func buildOffer(_ ctx: PeerSyncContext) -> [Data]? {
        // The link is up and answering, which is itself proof of life (`:328-330`). Committed
        // before any of the work below, because the reference commits it before the work below.
        peerLock.lock()
        alive = true
        lastHeard = ctx.now()
        syncBackoff = 0
        let minAcceptedCost = max(0, (propagationStampCost ?? 0)
                                     - (propagationStampCostFlexibility ?? 0))
        let transferLimit = propagationTransferLimit
        let syncLimit     = propagationSyncLimit
        peerLock.unlock()

        var candidates: [(id: Data, weight: Double, size: Int)] = []
        var purgedIDs:   [Data] = []
        var lowValueIDs: [Data] = []

        for tid in unhandledMessages {
            guard ctx.entryExists(tid) else { purgedIDs.append(tid); continue }
            if ctx.stampValue(tid) < minAcceptedCost {
                lowValueIDs.append(tid)
            } else {
                candidates.append((id: tid, weight: ctx.weight(tid), size: ctx.size(tid)))
            }
        }

        // Gone from the store, or too cheap for what this peer now demands: either way it will
        // never be sent, so stop carrying it (`:350-356`).
        for tid in purgedIDs   { removeUnhandledMessage(tid) }
        for tid in lowValueIDs { removeUnhandledMessage(tid) }

        // Ascending weight — `priorityWeight * ageWeight * size` (`LXMRouter.py:1056-1067`), not
        // receive time. With a per-sync limit the order decides what fits.
        candidates.sort { $0.weight < $1.weight }

        let perMessageOverhead = 16     // `:359` — really 2 bytes, held higher deliberately
        var cumulative         = 24     // `:360` — highest reasonable binary structure overhead
        var offerIDs: [Data] = []

        for candidate in candidates {
            let transferSize = candidate.size + perMessageOverhead
            let nextSize     = cumulative + transferSize

            // Bigger than this peer will accept in one message: it can never be delivered, so
            // record it as handled rather than re-offering it forever (`:370-373`).
            if let limit = transferLimit, transferSize > Int(limit * 1000) {
                addHandledMessage(candidate.id)
                removeUnhandledMessage(candidate.id)
                continue
            }
            // Over the per-sync budget: skipped, not dropped — a later sync carries it (`:375`).
            if let limit = syncLimit, nextSize >= Int(limit * 1000) { continue }

            cumulative += transferSize
            offerIDs.append(candidate.id)
        }

        return offerIDs.isEmpty ? nil : offerIDs
    }

    /// Send the offer request. Port of `LXMPeer.py:385-390`.
    private func sendOffer(_ ctx: PeerSyncContext) {
        guard let offerIDs = buildOffer(ctx) else { return }

        // ---- ORDERING B: commit, then request. ----
        // Python assigns `state = REQUEST_SENT` *after* `link.request` only because CPython
        // cannot deliver a response synchronously from inside it. This transport can. Committing
        // first is identical over a real network and correct over a synchronous one.
        peerLock.lock()
        guard let key = peeringKey else { peerLock.unlock(); return }
        lastOffer = offerIDs
        state = .requestSent
        let link = self.link
        peerLock.unlock()

        guard let link else { requestFailed(ctx); return }

        let payload = MsgPack.Value.array([
            .bytes(key.stamp),                              // the raw 32-byte stamp, never the value
            .array(offerIDs.map { .bytes($0) }),
        ])

        do {
            // `nativeValue:`, not `data:` — the latter wraps the payload as msgpack `.bytes`
            // (`LinkRequest.swift:316`) and a Python node rejects that. An offer larger than the
            // link MDU becomes an outbound Resource automatically (`:388`), which at 32-byte IDs
            // is the common case beyond about a dozen messages.
            try link.request(
                path: LXMPeer.offerRequestPath,
                nativeValue: payload,
                responseCallback: { [weak self] data, _ in self?.offerResponse(data, ctx) },
                failedCallback:   { [weak self] _, _ in self?.requestFailed(ctx) }
            )
        } catch {
            // Python ignores `link.request`'s return value (`:389`), which leaves the peer stuck
            // in REQUEST_SENT for a request that was never sent.
            requestFailed(ctx)
        }
    }

    /// The offer request could not be sent, or was never answered.
    /// Port of `LXMPeer.request_failed` (`LXMPeer.py:395-398`) — absent from this port until now.
    private func requestFailed(_ ctx: PeerSyncContext) {
        peerLock.lock()
        let link = self.link
        peerLock.unlock()

        if let link { try? link.teardown() }      // callout — may re-enter syncLinkClosed

        peerLock.lock()
        self.link = nil
        state = .idle
        peerLock.unlock()
    }

    // MARK: - The offer response

    /// Act on what the peer answered. Port of `LXMPeer.offer_response` (`LXMPeer.py:400-490`),
    /// **with its side effects** — the branches are not merely classified, they are carried out.
    private func offerResponse(_ data: Data, _ ctx: PeerSyncContext) {
        peerLock.lock()
        state = .responseReceived
        let offered = lastOffer
        peerLock.unlock()

        guard let response = try? MsgPack.decode(data) else {
            return abandonSync()                  // Python's except path (`:482-490`)
        }

        if let error = LXMPeerError(msgPack: response) {
            switch error {
            case .noIdentity:
                // The peer saw no identification. Identify again and re-run the pump with the
                // same offer (`:408-414`).
                peerLock.lock()
                let link = self.link
                let alreadyRetried = hasReIdentifiedOnThisLink
                hasReIdentifiedOnThisLink = true
                peerLock.unlock()

                guard let link else { break }     // no link: fall through to the empty-wanted path

                // Once per link. Python re-identifies unconditionally and would loop forever
                // against a peer that keeps answering 0xF0; it merely *looks* bounded there
                // because CPython cannot deliver a response from inside `link.request`, so each
                // retry starts a fresh stack. This transport can, and unbounded re-entry here is
                // a stack overflow rather than a slow loop. Identifying twice on one link
                // achieves nothing anyway.
                guard !alreadyRetried else { return abandonSync() }

                try? link.identify(as: ctx.routerIdentity)
                peerLock.lock(); state = .linkReady; peerLock.unlock()
                sync()                            // re-entry 2
                return

            case .noAccess:
                // Told we are not welcome. Break the peering rather than dial it forever
                // (`:416-419`). The link is left open, as Python leaves it; the reaper collects it.
                ctx.unpeer(destinationHash)
                return

            case .throttled:
                // Back off by the peer's throttle window rather than retrying into a refusal
                // (`:421-425`).
                peerLock.lock()
                nextSyncAttempt = ctx.now() + ctx.throttleWait
                peerLock.unlock()
                return

            case .invalidKey:
                // **A Swift-only branch.** Python has none: the integer falls into
                // `for transient_id in response`, raises `TypeError`, and lands in the except at
                // `:482-490` — which tears down and resets without touching the messages. Doing
                // that here is not enough, because the key it refused would be re-offered
                // unchanged on every subsequent sync. So the key is discarded and rebuilt, and
                // the offered messages stay **unhandled**: they were not delivered.
                //
                // Do not "restore parity" by routing this into the wants-nothing path. That marks
                // every offered message as delivered to a node that never received it.
                peerLock.lock(); peeringKey = nil; peerLock.unlock()
                return abandonSync()

            default:
                return abandonSync()
            }
        }

        var wantedIDs: [Data] = []

        switch response {
        case .bool(false):
            // The peer already holds everything offered (`:427-432`).
            let stillUnhandled = Set(unhandledMessages)
            for tid in offered where stillUnhandled.contains(tid) {
                addHandledMessage(tid)
                removeUnhandledMessage(tid)
            }

        case .bool(true):
            // It wants everything offered (`:435-439`). Entries that vanished from the store in
            // the meantime are dropped: Python indexes `propagation_entries[tid]` directly at
            // `:438` and would raise.
            wantedIDs = offered.filter { ctx.entryExists($0) }

        case .array(let wanted):
            let requested = wanted.compactMap { value -> Data? in
                if case .bytes(let b) = value { return Data(b) } else { return nil }
            }
            // Anything offered and not asked for, the peer already has from someone else — mark
            // it handled first, so a store that changes under us cannot lose the bookkeeping
            // (`:443-448`).
            let requestedSet = Set(requested)
            for tid in offered where !requestedSet.contains(tid) {
                addHandledMessage(tid)
                removeUnhandledMessage(tid)
            }
            wantedIDs = requested.filter { ctx.entryExists($0) }

        default:
            return abandonSync()
        }

        guard !wantedIDs.isEmpty else {
            // Nothing to send. Note `offered` accrues here but the persistent re-sync does not —
            // that belongs only to a completed transfer (`:475-480`).
            peerLock.lock()
            self.offered += offered.count
            let link = self.link
            peerLock.unlock()

            if let link { try? link.teardown() }
            peerLock.lock(); self.link = nil; state = .idle; peerLock.unlock()
            return
        }

        sendWantedMessages(wantedIDs, ctx)
    }

    /// Tear down and return to idle without touching message bookkeeping.
    /// Python's exception path (`LXMPeer.py:482-490`).
    private func abandonSync() {
        peerLock.lock()
        let link = self.link
        peerLock.unlock()

        if let link { try? link.teardown() }

        peerLock.lock()
        self.link = nil
        state = .idle
        peerLock.unlock()
    }

    // MARK: - The transfer

    /// Ship the wanted messages as one resource. Port of `LXMPeer.py:454-471`.
    private func sendWantedMessages(_ ids: [Data], _ ctx: PeerSyncContext) {
        // Files that vanished between the offer and now are skipped silently, exactly as Python
        // skips a missing path (`:459-464`). `bodies` can therefore be shorter than `ids`, and
        // `ids` is still what gets marked handled — faithful to `:469`.
        let bodies = ids.compactMap { ctx.messageBytes($0) }
        guard !bodies.isEmpty else {
            peerLock.lock()
            self.offered += lastOffer.count
            let link = self.link
            peerLock.unlock()
            if let link { try? link.teardown() }
            peerLock.lock(); self.link = nil; state = .idle; peerLock.unlock()
            return
        }

        // `[timestamp, [whole message files]]` (`:466`). Each element is the on-disk file
        // verbatim — LXMF bytes with the 32-byte propagation stamp still attached — because the
        // receiver splits the stamp back off and validates it (`LXStamper.py:84-96`).
        let payload = MsgPack.encode(.array([
            .double(ctx.now()),
            .array(bodies.map { .bytes($0) }),
        ]))

        peerLock.lock()
        let link = self.link
        peerLock.unlock()
        guard let link else { return abandonSync() }

        let transfer = ResourceTransfer(link: link)
        transfer.onComplete = { [weak self] completed in
            self?.resourceConcluded(completed, success: true)
        }
        transfer.onFailed = { [weak self] failed, _ in
            self?.resourceConcluded(failed, success: false)
        }

        // ---- ORDERING C: commit the index, then send. ----
        // A synchronous conclusion inside `send` would otherwise find
        // `currentlyTransferringMessages == nil`, take the abort branch below, and leave the
        // interlock at `:315-317` armed forever — no further sync would ever start.
        peerLock.lock()
        currentlyTransferringMessages = ids
        currentSyncTransferStarted    = ctx.now()
        state = .resourceTransferring
        peerLock.unlock()

        do {
            // Never `segmentSize:` — the receiver derives its own part count from its view of the
            // link, and a disagreement means the transfer never completes
            // (`ResourceTransfer.swift:406-414`).
            try transfer.send(payload: payload)
        } catch {
            resourceConcluded(transfer, success: false)
        }
    }

    /// The resource finished, one way or the other. Port of `LXMPeer.resource_concluded`
    /// (`LXMPeer.py:492-532`).
    ///
    /// Takes the transfer rather than a size, because Python reads **two different sizes** from
    /// it: the compressed `get_transfer_size()` for the rate (`:510`) and the uncompressed
    /// `get_data_size()` for `tx_bytes` (`:518`). The old `dataSizeBytes: Int` parameter could
    /// only carry one.
    private func resourceConcluded(_ transfer: ResourceTransfer, success: Bool) {
        peerLock.lock()
        let transferring = currentlyTransferringMessages
        let offerCount   = lastOffer.count
        let startedAt    = currentSyncTransferStarted
        let link         = self.link
        peerLock.unlock()

        guard success else {
            // Nothing is marked handled and no statistic moves: the messages are still owed and
            // the next sync offers them again (`:526-532`).
            if let link { try? link.teardown() }
            peerLock.lock()
            self.link = nil
            state = .idle
            currentlyTransferringMessages = nil
            currentSyncTransferStarted    = nil
            peerLock.unlock()
            return
        }

        guard let transferring else {
            // Python logs this and then falls into `for transient_id in None` (`:494-498`) — it
            // is missing the `return` its own log message says it takes.
            if let link { try? link.teardown() }
            peerLock.lock()
            self.link = nil
            state = .idle
            peerLock.unlock()
            return
        }

        for tid in transferring {                 // `:500-502`
            addHandledMessage(tid)
            removeUnhandledMessage(tid)
        }

        if let link { try? link.teardown() }      // callout — may re-enter syncLinkClosed

        peerLock.lock()
        self.link = nil
        state = .idle
        // Guarded, as Python guards it (`:509`) — an aborted transfer can conclude with no start
        // time, and dividing by `now - nil` is not a thing that has a sensible answer.
        if let startedAt {
            let elapsed = ctx_elapsed(since: startedAt)
            if elapsed > 0 {
                // Compressed size: this is a measure of the link, and `syncPeers` ranks its
                // candidate pool by it (`LXMRouter.swift:3060`).
                syncTransferRate = Double(transfer.transferSize * 8) / elapsed
            }
        }
        alive     = true
        lastHeard = Date().timeIntervalSince1970
        offered  += offerCount
        outgoing += transferring.count
        // Uncompressed: `tx_bytes` is what an operator reads to size a link, so it counts the
        // payload, not what the wire happened to squeeze it to (`:518`).
        txBytes  += transfer.dataSize
        currentlyTransferringMessages = nil
        currentSyncTransferStarted    = nil
        let strategy = syncStrategy
        peerLock.unlock()

        // Drain the rest of the backlog now rather than waiting 24 s for the next scheduled pass
        // (`:523-524`). Dispatched, not called inline: over a synchronous transport an inline
        // call would recurse a whole store's worth of syncs onto one stack.
        if strategy == .persistent, unhandledMessageCount > 0 {
            peeringKeyQueue.async { [weak self] in self?.sync() }
        }
    }

    private func ctx_elapsed(since start: TimeInterval) -> TimeInterval {
        Date().timeIntervalSince1970 - start
    }


    // MARK: - Name (from metadata)

    /// Display name from peer announce metadata.
    public var name: String? {
        guard let metadata else { return nil }
        return metadata["name"]
    }
}
