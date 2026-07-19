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

    /// Proof-of-work peering key for this peer: [stampData, value] or nil.
    public var peeringKey: (stamp: Data, value: Int)? = nil

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
        let peeringKeyReady: Bool = {
            guard let pk = peeringKey, let cost = peeringCost else { return false }
            return pk.value >= cost
        }()

        peerLock.lock()
        lastSyncAttempt = now
        let syncTimeReached = now > nextSyncAttempt
        let syncChecks = syncTimeReached && stampCostsKnown && peeringKeyReady
        guard syncChecks else {
            // Postpone; if time has passed but last attempt > last_heard, mark not alive
            if !syncTimeReached && now > lastHeard { alive = false }
            peerLock.unlock()
            return
        }
        peerLock.unlock()

        // `unhandledMessageCount` self-locks (and routes through the router), so read it
        // WITHOUT `peerLock` held. Guard order is preserved: unhandled>0, then
        // currentlyTransferring==nil, then state==idle.
        guard unhandledMessageCount > 0 else { return }  // nothing to send

        peerLock.lock()
        guard currentlyTransferringMessages == nil else { peerLock.unlock(); return }  // transfer in progress
        guard state == .idle else { peerLock.unlock(); return }  // link already in progress

        // In a real implementation this would open an RNS Link.
        // The state machine is tested via manual state injection.
        syncBackoff += LXMPeer.syncBackoffStep
        nextSyncAttempt = now + syncBackoff
        state = .linkEstablishing
        peerLock.unlock()
    }

    /// Called when the sync link has been established.
    /// Mirrors Python's `LXMPeer.link_established(link)`.
    public func linkEstablished(_ link: Link) {
        peerLock.lock()
        self.link  = link
        self.state = .linkReady
        nextSyncAttempt = 0
        peerLock.unlock()
    }

    /// Called when the sync link closes.
    /// Mirrors Python's `LXMPeer.link_closed(link)`.
    public func linkClosed(_ link: Link) {
        peerLock.lock()
        self.link  = nil
        self.state = .idle
        peerLock.unlock()
    }

    // MARK: - Offer/response flow

    /// Build the offer payload for this peer (list of transient IDs we have that the peer needs).
    /// Returns nil if there is nothing to offer.
    /// Mirrors the LINK_READY branch of Python's `LXMPeer.sync()`.
    public func buildOffer() -> (peeringStamp: Data, transientIDs: [Data])? {
        guard let pk = peeringKey else { return nil }
        guard let router else { return nil }

        let minAcceptedCost = max(0, (propagationStampCost ?? 0) - (propagationStampCostFlexibility ?? 0))
        let perMsgOverhead  = 16
        let cumulativeSize  = 24

        var unhandledEntries: [(id: Data, weight: TimeInterval, size: Int)] = []
        var purgedIDs: [Data] = []
        var lowValueIDs: [Data] = []

        for tid in unhandledMessages {
            if let entry = router.peerEntry(tid) {
                if entry.stampValue < minAcceptedCost {
                    lowValueIDs.append(tid)
                } else {
                    unhandledEntries.append((id: tid, weight: entry.received, size: entry.msgSize))
                }
            } else {
                purgedIDs.append(tid)
            }
        }

        for tid in purgedIDs   { removeUnhandledMessage(tid) }
        for tid in lowValueIDs { removeUnhandledMessage(tid) }

        // Sort by receive time ascending (oldest first)
        unhandledEntries.sort { $0.weight < $1.weight }

        var finalIDs: [Data] = []
        var cumulative = cumulativeSize

        for entry in unhandledEntries {
            let transferSize = entry.size + perMsgOverhead
            let nextSize     = cumulative + transferSize

            if let ptl = propagationTransferLimit, transferSize > Int(ptl * 1000) {
                addHandledMessage(entry.id)
                removeUnhandledMessage(entry.id)
                continue
            }
            if let psl = propagationSyncLimit, nextSize >= Int(psl * 1000) { continue }

            cumulative += transferSize
            finalIDs.append(entry.id)
        }

        guard !finalIDs.isEmpty else { return nil }
        return (pk.stamp, finalIDs)
    }

    /// Handle an offer response from the remote peer.
    /// Returns transient IDs of messages we should send (empty = send nothing).
    /// Mirrors Python's `LXMPeer.offer_response(request_receipt)`.
    ///
    /// `response` is the decoded response from the offer request:
    ///   - `.nil` / empty array → peer has all messages
    ///   - `true`  → peer wants all offered messages
    ///   - `false` → peer wants none (already has all)
    ///   - [ids]   → peer wants only these IDs
    public enum OfferResponse {
        case allWanted      // send all lastOffer IDs
        case noneWanted     // mark all lastOffer as handled
        case partialWanted([Data])  // send only these
        case error(LXMPeerError)
    }

    public func processOfferResponse(_ response: MsgPack.Value) -> OfferResponse {
        // Commit the state transition and snapshot `lastOffer` under the lock; the
        // add/remove calls below self-lock (and route through the router), so they run
        // OUTSIDE the lock against the snapshot.
        peerLock.lock()
        state = .responseReceived
        let offerSnapshot = lastOffer
        peerLock.unlock()

        switch response {
        case .int(let code) where code == Int64(LXMPeerError.noIdentity.rawValue):
            return .error(.noIdentity)
        case .int(let code) where code == Int64(LXMPeerError.noAccess.rawValue):
            return .error(.noAccess)
        case .int(let code) where code == Int64(LXMPeerError.throttled.rawValue):
            return .error(.throttled)
        case .bool(false):
            // Peer has all our offered messages
            for tid in offerSnapshot {
                addHandledMessage(tid)
                removeUnhandledMessage(tid)
            }
            return .noneWanted
        case .bool(true):
            // Peer wants all offered messages
            return .allWanted
        case .array(let wantedArr):
            // Peer wants a subset
            let wantedIDs = wantedArr.compactMap { (v) -> Data? in
                if case .bytes(let b) = v { return Data(b) }
                return nil
            }
            for tid in offerSnapshot where !wantedIDs.contains(tid) {
                addHandledMessage(tid)
                removeUnhandledMessage(tid)
            }
            return .partialWanted(wantedIDs)
        default:
            return .noneWanted
        }
    }

    /// Called when a resource transfer to this peer completes.
    /// Mirrors Python's `LXMPeer.resource_concluded(resource)`.
    public func resourceConcluded(success: Bool, dataSizeBytes: Int) {
        // Snapshot the state the callouts need under the lock; run the router
        // add/remove calls, the link teardown, and the optional re-sync OUTSIDE the lock
        // (they self-lock / re-enter linkClosed / reacquire peerLock via sync()); then
        // commit the counter/flag updates and the state resets under the lock.
        peerLock.lock()
        let transferring   = currentlyTransferringMessages ?? []
        let offerCount     = lastOffer.count
        let linkToTeardown = link
        peerLock.unlock()

        if success {
            for tid in transferring {
                addHandledMessage(tid)
                removeUnhandledMessage(tid)
            }
        }

        if let l = linkToTeardown { try? l.teardown() }   // callout (may re-enter linkClosed)

        peerLock.lock()
        if success {
            offered  += offerCount
            outgoing += transferring.count
            txBytes  += dataSizeBytes

            alive      = true
            lastHeard  = Date().timeIntervalSince1970
            syncBackoff = 0
        }
        link       = nil
        state      = .idle
        currentlyTransferringMessages = nil
        peerLock.unlock()

        if success, syncStrategy == .persistent, unhandledMessageCount > 0 {
            sync()
        }
    }

    // MARK: - Name (from metadata)

    /// Display name from peer announce metadata.
    public var name: String? {
        guard let metadata else { return nil }
        return metadata["name"]
    }
}
