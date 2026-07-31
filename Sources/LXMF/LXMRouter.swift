import Foundation
import ReticulumSwift

// MARK: - LXMRouterError

public enum LXMRouterError: Error, Equatable {
    /// Thrown when attempting to send a propagated message without a configured propagation node.
    /// Mirrors Python `IOError("Attempt to send propagated message with no outbound propagation node configured")`.
    case noPropagationNode
}

// MARK: - PropagationTransferState

/// State machine for inbound propagation node sync.
/// Mirrors Python `LXMRouter.PR_*` constants.
public enum PropagationTransferState: Equatable {
    /// No sync in progress.
    case idle
    /// Path request sent; waiting for a path to the propagation node.
    case pathRequested
    /// Link is being established to the propagation node.
    case linkEstablishing
    /// Link is established; ready to send a request.
    case linkEstablished
    /// Message-list request sent; waiting for response.
    case requestSent
    /// Downloading messages.
    case receiving
    /// All messages downloaded successfully.
    case done
    /// Sync failed.
    case failed
}

// MARK: - LXMRouter

/// LXMF message router. Manages outbound delivery and inbound reception
/// for one or more registered delivery identities.
///
/// Mirrors the core delivery loop of Python's `LXMRouter`:
///   * Opportunistic — send as a plain RNS Packet without establishing a link.
///   * Direct        — establish an RNS Link and deliver as a packet (small
///                     messages) or Resource (large messages).
///
public final class LXMRouter {

    // MARK: - Constants

    public static let maxDeliveryAttempts = 5
    public static let maxPathlessTries    = 2
    public static let deliveryRetryWait: TimeInterval = 12
    public static let pathRequestWait: TimeInterval   = 15

    /// RNS request path for fetching/delivering messages to/from a propagation node.
    /// Mirrors Python `LXMPeer.MESSAGE_GET_PATH = "/get"`.
    public static let messageGetPath = LXMPeer.messageGetPath
    /// Timeout when waiting for a path to a propagation node.
    /// Mirrors Python `LXMRouter.PR_PATH_TIMEOUT`.
    public static let prPathTimeout: TimeInterval = 10.0

    /// Whether a node peers automatically by default. Python: `LXMRouter.AUTOPEER = True` (`:44`).
    public static let defaultAutopeer = true
    /// Default automatic peering depth, in hops.
    /// Python: `LXMRouter.AUTOPEER_MAXDEPTH = 4` (`:45`).
    public static let defaultAutopeerMaxdepth = 4
    /// Default ceiling on the peer table. Python: `LXMRouter.MAX_PEERS = 20` (`:43`).
    public static let defaultMaxPeers = 20
    /// Default ceiling on a remote's peering cost.
    /// Python: `LXMRouter.MAX_PEERING_COST = 26` (`:51`).
    public static let defaultMaxPeeringCost = 26
    /// Fraction of `maxPeers` rotation tries to keep free.
    /// Python: `LXMRouter.ROTATION_HEADROOM_PCT = 10` (`:47`).
    public static let rotationHeadroomPct = 10
    /// Acceptance rate at or above which a peer is never rotated out.
    /// Python: `LXMRouter.ROTATION_AR_MAX = 0.5` (`:48`).
    public static let rotationAcceptanceRateMax = 0.5
    /// How many of the fastest waiting peers form the sync-selection pool.
    /// Python: `LXMRouter.FASTEST_N_RANDOM_POOL = 2` (`:46`).
    public static let fastestNRandomPool = 2
    /// How long a remote is refused after sending messages with invalid stamps.
    /// Python: `LXMRouter.PN_STAMP_THROTTLE = 180` (`:63`).
    public static let pnStampThrottle: TimeInterval = 180

    // MARK: - State

    private let transport: Transport
    private let lock = NSLock()

    /// The local LXMF identity (set by the first `register(identity:transport:)` call).
    public private(set) var identity: Identity? = nil

    /// Registered inbound delivery destinations, keyed by their hash.
    private(set) var deliveryDestinations: [Data: Destination] = [:]

    /// Active outbound direct links, keyed by the remote destination hash.
    private(set) var directLinks: [Data: Link] = [:]

    /// Messages awaiting delivery.
    private(set) var pendingOutbound: [LXMessage] = []

    /// Delivered or failed messages available for the caller.
    public var onMessageReceived: ((LXMessage) -> Void)?

    /// Hash of the propagation node to use for outbound propagated delivery.
    /// Mirrors Python's `LXMRouter.outbound_propagation_node`.
    public var outboundPropagationNode: Data?

    /// Active link to the propagation node. Reused across messages.
    var outboundPropagationLink: Link?

    // MARK: - Propagation sync state

    /// Current state of an in-progress propagation sync transfer.
    /// Mirrors Python's `LXMRouter.propagation_transfer_state`.
    public var propagationTransferState: PropagationTransferState = .idle

    /// Progress of the current propagation sync (0.0–1.0).
    /// Mirrors Python's `LXMRouter.propagation_transfer_progress`.
    public var propagationTransferProgress: Double = 0.0

    /// Size in bytes of the in-flight propagation-node message-get response, or
    /// `nil` when no sync is running. Lets a UI render "x of y bytes" instead of
    /// only a fraction. Reset on every new sync request and on completion or
    /// failure. Mirrors Python's `LXMRouter.propagation_transfer_size`.
    public var propagationTransferSize: Int? = nil

    /// Maximum messages to fetch (nil = all).
    /// Mirrors Python's `LXMRouter.propagation_transfer_max_messages` (PR_ALL_MESSAGES = -1 → nil).
    public var propagationTransferMaxMessages: Int? = nil

    /// Maximum messages per single GET transfer (nil = no limit).
    /// Mirrors Python's `LXMRouter.delivery_per_transfer_limit`.
    public var deliveryPerTransferLimit: Int? = nil

    /// Whether to keep messages on the propagation node after confirming receipt.
    /// Mirrors Python's `LXMRouter.retain_synced_on_node`.
    public var retainSyncedOnNode: Bool = false

    /// Propagation node we're waiting to get a path to, before re-attempting sync.
    /// Mirrors Python's `LXMRouter.wants_download_on_path_available_from`.
    public var wantsDownloadOnPathAvailableFrom: Data? = nil

    // MARK: - Auth and allow/disallow lists

    /// Whether authentication is required for inbound messages.
    /// Python: `LXMRouter.auth_required`.
    private var authRequired: Bool = false

    /// Whitelist of identity hashes allowed to send messages when auth is required.
    /// Python: `LXMRouter.allowed_list`.
    private var allowedList: Set<Data> = []

    /// Locally delivered transient IDs, mapped to when they were delivered
    /// (for `has_message`). The timestamp is what lets `cleanTransientIDCaches`
    /// expire them — without it the cache grows for the lifetime of the install
    /// and is persisted to disk in full on every save.
    /// Mirrors Python's `locally_delivered_transient_ids` dict.
    var locallyDeliveredTransientIDs: [Data: TimeInterval] = [:]

    /// Transient IDs a propagation node has already handled and since dropped
    /// from `propagationEntries`. Acts as a tombstone set so a message that was
    /// delivered and pruned is not silently re-ingested the next time a peer
    /// offers it. Mapped to when it was processed, and expired on the same
    /// schedule as the delivered cache.
    /// Mirrors Python's `locally_processed_transient_ids` dict.
    var locallyProcessedTransientIDs: [Data: TimeInterval] = [:]

    /// How long a transient ID stays in the delivered/processed caches.
    /// Mirrors Python's `MESSAGE_EXPIRY * 6.0` (30 days x 6 = 180 days).
    static let transientIDCacheExpiry: TimeInterval = 30 * 24 * 60 * 60 * 6.0

    /// Job ticks between transient-ID cache reaps.
    /// Mirrors Python's `LXMRouter.JOB_TRANSIENT_INTERVAL = 60`.
    static let jobTransientInterval = 60

    // MARK: - Priority and ignore lists

    /// Destinations that should receive priority delivery.
    /// Mirrors Python's `LXMRouter.prioritised_list`.
    private var prioritisedList: [Data] = []

    /// Whether stamp enforcement is enabled for inbound messages.
    /// Mirrors Python's `LXMRouter.enforce_stamps` flag.
    private var enforceStamps_: Bool = false

    /// Destinations whose inbound messages should be silently ignored.
    /// Mirrors Python's `LXMRouter.ignored_list`.
    private var ignoredList: [Data] = []

    // MARK: - Delivery destination display names

    /// Display name per registered delivery destination hash.
    /// Set at `register(identity:transport:displayName:)` time.
    /// Mirrors Python's `delivery_destination.display_name`.
    private var deliveryDestinationNames: [Data: String] = [:]

    // MARK: - Pending signature validation

    /// Inbound messages waiting for the source identity to arrive (via announce)
    /// before their signature can be validated. Keyed entry holds the received
    /// message and the time it arrived (for diagnostics / timeout ordering).
    ///
    /// The `DeliveryAnnounceHandler` fires when the source's lxmf.delivery
    /// announce is processed — at that point `transport.recall(identity:)` already
    /// has the identity, so validation is immediate rather than poll-based.
    ///
    /// NOTE: Inbound delivery no longer *defers* messages from unknown sources —
    /// they are delivered immediately as unverified, matching Python (bug 006), so
    /// this queue is normally empty. `notifyAnnounced` still drains it (a harmless
    /// no-op) and remains as a public hook for callers that queue messages here
    /// through some other path.
    private var pendingSignatureValidation: [(message: LXMessage, received: Date)] = []

    // MARK: - Ticket store

    /// Outbound tickets received from remote routers: [destHash: (expiry, ticket)].
    /// Mirrors Python's `available_tickets["outbound"]`.
    private var outboundTickets: [Data: (expiry: TimeInterval, ticket: Data)] = [:]

    /// Inbound tickets we generated for remote peers: [destHash: [ticket: expiry]].
    /// Mirrors Python's `available_tickets["inbound"]`.
    private var inboundTickets_: [Data: [Data: TimeInterval]] = [:]

    /// Timestamps of the last ticket delivered to each destination.
    /// Mirrors Python's `available_tickets["last_deliveries"]`.
    private var lastDeliveries: [Data: TimeInterval] = [:]

    // MARK: - Stamp cost tables

    /// Per-destination inbound stamp cost overrides.
    private var inboundStampCosts: [Data: Int?] = [:]

    /// Per-destination outbound stamp costs (learned from announces).
    private(set) var outboundStampCosts: [Data: Int] = [:]

    // MARK: - Propagation node server state

    /// Whether this router is currently acting as a propagation node.
    /// Python: `LXMRouter.propagation_node`.
    public private(set) var isPropagationNode: Bool = false

    /// Time when propagation was enabled.
    public private(set) var propagationNodeStartTime: TimeInterval? = nil

    /// The local LXMF propagation destination (lxmf.propagation, direction IN).
    /// Created once on the first `register(identity:transport:)` call, mirroring
    /// Python's `__init__`: `self.propagation_destination = RNS.Destination(self.identity, IN, SINGLE, APP_NAME, "propagation")`.
    public private(set) var propagationDestination: Destination? = nil

    /// All known propagation peers, keyed by destination hash.
    /// Python: `LXMRouter.peers`.
    public var propagationEntries: [Data: PropagationEntry] = [:]

    /// All stored messages, keyed by transient ID.
    /// Python: `LXMRouter.propagation_entries`.
    public var peers: [Data: LXMPeer] = [:]

    /// Whether to enforce ratchet usage on registered delivery destinations.
    /// When true, register() calls enforceRatchets() on the delivery destination
    /// after enabling ratchets. Mirrors Python `LXMRouter.__init__(enforce_ratchets=False)`.
    public var enforceRatchets: Bool = false

    /// Root storage path for LXMF data (storagepath/lxmf).
    ///
    /// Setting this loads any persisted client state (locally-delivered transient
    /// ids, outbound stamp costs, available tickets) from disk, mirroring Python
    /// `LXMRouter.__init__`, which reads these files at startup. Subsequent
    /// mutations write them back atomically.
    public var storagePath: String? = nil {
        didSet { if storagePath != nil { loadPersistedClientState() } }
    }

    /// Path to the message store directory (storagePath/messagestore).
    public var messagePath: String? = nil

    /// Maximum total bytes for the message store. nil = unlimited.
    /// Python: `LXMRouter.message_storage_limit`.
    public var messageStorageLimit: Int? = nil

    /// Maximum bytes per peer sync transfer (KB). nil = unlimited.
    public var propagationPerTransferLimit: Int? = nil

    /// Maximum bytes per sync session (KB). nil = unlimited.
    public var propagationPerSyncLimit: Int? = nil

    /// Minimum proof-of-work stamp cost required for messages accepted by this node.
    public var propagationStampCost: Int = 0

    /// Flexibility (±) on the stamp cost requirement.
    public var propagationStampCostFlexibility: Int = 0

    /// PoW cost for peering with this node.
    public var peeringCost: Int = 0

    /// Whether to peer automatically with propagation nodes discovered through incoming syncs.
    /// Python: `LXMRouter.AUTOPEER = True` (`LXMRouter.py:44`), consulted at `:2365`.
    public var autopeer: Bool = LXMRouter.defaultAutopeer

    /// The greatest number of peers this node will hold.
    /// Python: `LXMRouter.MAX_PEERS = 20` (`LXMRouter.py:43`), per-node at `:206`.
    public var maxPeers: Int = LXMRouter.defaultMaxPeers

    /// The highest peering cost this node is willing to pay to peer with a remote.
    /// Python: `LXMRouter.max_peering_cost` (`:150`), applied at `:2005`.
    public var maxPeeringCost: Int = LXMRouter.defaultMaxPeeringCost

    /// Propagation destinations this node is always peered with, by destination hash.
    ///
    /// Python: `LXMRouter.static_peers` (`:211-219`). A static peer is the operator's declared
    /// upstream rather than a discovered one, so it is exempt from rotation (`:2092`) and from the
    /// unreachability cull (`:2140`) — losing it is not something discovery can repair.
    public var staticPeers: Set<Data> = []

    /// Whether rotation drops only unreachable peers when any exist, rather than considering
    /// merely-waiting ones alongside them.
    /// Python: `LXMRouter.prioritise_rotating_unreachable_peers` (`:167`), consumed at `:2104`.
    public var prioritiseRotatingUnreachablePeers: Bool = false

    /// The furthest, in hops, a node may be and still be peered with automatically.
    ///
    /// Python: `LXMRouter.AUTOPEER_MAXDEPTH = 4` (`:45`). Note that `lxmd`'s example configuration
    /// suggests 6 (`Utilities/lxmd.py:995`) — that is the daemon's suggestion to an operator, not
    /// the router's default, and the port keeps both as the reference has them.
    public var autopeerMaxdepth: Int = LXMRouter.defaultAutopeerMaxdepth

    /// Remotes whose offers are refused until the recorded time, keyed by propagation destination
    /// hash. Python: `LXMRouter.throttled_peers` (`LXMRouter.py:154`).
    public var throttledPeers: [Data: TimeInterval] = [:]

    /// Active inbound propagation links from peers/clients.
    public var activePropagationLinks: [ObjectIdentifier: Link] = [:]

    /// Link IDs that have been validated as coming from authenticated peers.
    public var validatedPeerLinks: [ObjectIdentifier: Bool] = [:]

    /// Queue of transient IDs waiting to be distributed to peers.
    public var peerDistributionQueue: [Data] = []

    /// Number of messages received from unpeered clients.
    public var clientPropagationMessagesReceived: Int = 0

    /// Number of messages served to clients.
    public var clientPropagationMessagesServed: Int = 0

    /// Number of propagation messages from unpeered nodes.
    public var unpeeredPropagationIncoming: Int = 0

    /// Bytes received from unpeered propagation sources.
    public var unpeeredPropagationRxBytes: Int = 0

    // Announce handlers kept alive so ARC doesn't release them.
    private var deliveryAnnounceHandler: DeliveryAnnounceHandler!
    private var propagationNodeAnnounceHandler: PropagationNodeAnnounceHandler!

    /// Periodic job timer — mirrors Python's `LXMRouter.jobloop()` / `PROCESSING_INTERVAL = 4`.
    private var jobTimer: DispatchSourceTimer?

    /// How many job ticks between reaps of `incomingDeliveryResources`.
    /// Mirrors Python's `LXMRouter.JOB_RESOURCE_INTERVAL = 2` (so every 8 s at
    /// the 4 s processing interval).
    static let jobResourceInterval = 2

    /// Job-loop tick counter, used to phase the resource reap.
    /// Mirrors Python's `LXMRouter.processing_count`.
    private var processingCount = 0

    /// In-flight inbound message resource transfers, keyed by resource hash.
    /// Lets a UI show what is currently arriving and cancel it mid-transfer.
    /// Mirrors Python's `LXMRouter.incoming_delivery_resources`.
    private var incomingDeliveryResources: [Data: ResourceTransfer] = [:]

    /// Guards `incomingDeliveryResources`. Kept separate from the router's main
    /// `lock` so a resource callback firing on a link's receive thread never
    /// contends with outbound processing.
    /// Mirrors Python's `incoming_delivery_resource_lock`.
    private let incomingDeliveryResourceLock = NSLock()

    // MARK: - Init

    public init(transport: Transport) {
        self.transport = transport
        deliveryAnnounceHandler = DeliveryAnnounceHandler(router: self)
        propagationNodeAnnounceHandler = PropagationNodeAnnounceHandler(router: self)
        transport.register(announceHandler: deliveryAnnounceHandler)
        transport.register(announceHandler: propagationNodeAnnounceHandler)
        startJobLoop()
    }

    deinit {
        jobTimer?.cancel()
        transport.deregister(announceHandler: deliveryAnnounceHandler)
        transport.deregister(announceHandler: propagationNodeAnnounceHandler)
    }

    // MARK: - Job loop (mirrors Python LXMRouter.jobloop / PROCESSING_INTERVAL = 4 s)

    private func startJobLoop() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // Repeat every 4 s, first fire after 4 s (no need to run immediately on start).
        timer.schedule(deadline: .now() + 4, repeating: 4)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.processingCount &+= 1
            self.processOutbound()
            // Mirrors Python's jobs(): the resource reap runs on every
            // JOB_RESOURCE_INTERVAL-th tick, not every tick.
            if self.processingCount % LXMRouter.jobResourceInterval == 0 {
                self.cleanResourceTracking()
            }
            if self.processingCount % LXMRouter.jobTransientInterval == 0 {
                self.cleanTransientIDCaches()
                self.saveLocallyDeliveredTransientIDs()
                self.saveLocallyProcessedTransientIDs()
            }
        }
        timer.resume()
        jobTimer = timer
    }

    // MARK: - Destination registration

    /// Register a local LXMF delivery destination. Inbound messages
    /// addressed to this destination will be decoded and delivered via
    /// `onMessageReceived`. Mirrors Python's `LXMRouter.register_delivery_identity`.
    ///
    /// - Parameters:
    ///   - identity: The local identity to register.
    ///   - transport: The active `Transport` instance.
    ///   - displayName: Optional human-readable name for this node, included in
    ///     announce app data. Mirrors Python's `display_name` parameter.
    @discardableResult
    public func register(identity: Identity, transport: Transport,
                         displayName: String? = nil) throws -> Destination {
        let delivery = try Destination(
            identity: identity,
            direction: .in,
            kind: .single,
            appName: APP_NAME,
            aspects: ["delivery"]
        )
        lock.lock()
        let isFirst = self.identity == nil
        if isFirst { self.identity = identity }
        deliveryDestinations[delivery.hash] = delivery
        if let name = displayName { deliveryDestinationNames[delivery.hash] = name }
        lock.unlock()

        // Enable ratchets when a storage path is configured (mirrors Python register() which
        // always calls enable_ratchets with a per-destination file under storagepath/ratchets/).
        if let storagePath {
            let hexHash = delivery.hash.map { String(format: "%02x", $0) }.joined()
            let ratchetFile = URL(fileURLWithPath: storagePath)
                .appendingPathComponent("ratchets")
                .appendingPathComponent("\(hexHash).ratchets")
            try? delivery.enableRatchets(path: ratchetFile)
        }
        if enforceRatchets {
            delivery.enforceRatchets()
        }

        // Create the propagation destination once (mirrors Python __init__ line 172).
        if isFirst, let propDest = try? Destination(
            identity: identity, direction: .in, kind: .single,
            appName: APP_NAME, aspects: ["propagation"]
        ) {
            lock.lock(); propagationDestination = propDest; lock.unlock()
            transport.register(destination: propDest)
        }

        transport.register(destination: delivery)
        transport.onPacketDelivered = { [weak self] packet, dest, _ in
            self?.handleInboundPacket(packet, destination: dest)
        }

        // When a remote peer establishes a delivery link to us, configure it to handle
        // both small messages (link DATA packets) and large messages (Resource).
        delivery.onLinkEstablished = { [weak self] link in
            guard let self else { return }

            // Small message: plain data packet on the link.
            //
            // Python wire format differences by delivery method:
            //   DIRECT     — sender puts self.packed (FULL bytes, dest hash included) on the link.
            //                 Receiver's delivery_packet: `lxmf_data = data` — no prefix added.
            //   OPPORTUNISTIC — sender strips dest hash: `packed[DESTINATION_LENGTH:]`.
            //                   Receiver's delivery_packet: prepends `packet.destination.hash + data`.
            //
            // For link-based (DIRECT) delivery, `data` already contains the full packed message.
            // Do NOT prepend destHash — it's already the first 16 bytes of `data`.
            link.onDataReceived = { [weak self] data, inboundLink in
                // Prove receipt immediately — mirrors Python LXMRouter.delivery_packet
                // which calls `packet.prove()` before any other processing (line 1825).
                // Without this, the sender's PacketReceipt times out and the message
                // is retransmitted in a loop.
                inboundLink.proveInboundData()

                guard let self else { return }
                guard let msg = try? LXMessage.unpack(data) else { return }
                // Drop messages from blackholed source identities before any
                // delivery. Mirrors Python `LXMRouter.lxmf_delivery` blackhole
                // check (LXMF commit 2ac2b10).
                if msg.sourceBlackholed { return }
                msg.incoming = true
                msg.state = .delivered

                // Validate the signature if the source identity is known;
                // otherwise deliver immediately as unverified (SOURCE_UNKNOWN),
                // matching Python — never hold the message back. See bug 006.
                if let srcIdentity = self.transport.recall(identity: msg.sourceHash) {
                    msg.validateSignature(knownIdentity: srcIdentity)
                    self.finalizeInboundDelivery(msg)
                } else {
                    self.deliverWithUnknownSource(msg)
                }
            }

            // Large message: resource transfer (full packed bytes including dest hash).
            link.resourceStrategy = .acceptApp
            // Check per-transfer size limit. Mirrors Python's delivery_resource_advertised.
            link.onResourceAdvertised = { [weak self] resource, _ -> Bool in
                guard let self else { return true }
                if let limitKB = self.deliveryPerTransferLimit {
                    return Int(resource.dataSize) <= limitKB * 1000
                }
                return true
            }
            // Register the transfer as it begins so it can be listed and
            // cancelled while it is still arriving.
            // Mirrors Python's `delivery_resource_transfer_began` callback.
            link.onResourceStarted = { [weak self] transfer in
                self?.trackIncomingDeliveryResource(transfer)
            }
            link.onResourceConcluded = { [weak self] data, _, _ in
                self?.deliverInboundResource(data)
            }
        }
        return delivery
    }

    // MARK: - Delivery destination announce API

    /// Update the display name for an already-registered delivery destination.
    ///
    /// The new name is embedded in the next `announce()` call; it does not
    /// trigger an announce itself.  Pass `nil` to remove the name.
    ///
    /// Mirrors the Python attribute assignment `lxmf_destination.display_name = name`.
    public func setDisplayName(_ name: String?, forDestinationHash hash: Data) {
        lock.lock(); defer { lock.unlock() }
        guard deliveryDestinations[hash] != nil else { return }
        if let name, !name.isEmpty {
            deliveryDestinationNames[hash] = name
        } else {
            deliveryDestinationNames.removeValue(forKey: hash)
        }
    }

    /// Build the msgpack announce app data for a registered delivery destination.
    ///
    /// Format: `[display_name_bytes_or_nil, stamp_cost_or_nil]`
    ///
    /// - `display_name`: UTF-8 encoded name bytes, or nil if not set.
    /// - `stamp_cost`: integer in 1…254, or nil if not set / out of range.
    ///
    /// Returns `nil` for destinations that have not been registered with this router.
    ///
    /// Mirrors Python's `LXMRouter.get_announce_app_data(destination_hash)`.
    public func getAnnounceAppData(destinationHash: Data) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard deliveryDestinations[destinationHash] != nil else { return nil }

        // Display name: UTF-8 bytes or nil
        let displayNameValue: MsgPack.Value
        if let name = deliveryDestinationNames[destinationHash],
           let bytes = name.data(using: .utf8) {
            displayNameValue = .bytes(bytes)
        } else {
            displayNameValue = .nil
        }

        // Stamp cost: integer in 1…254 or nil
        let stampCostValue: MsgPack.Value
        if let maybeInt = inboundStampCosts[destinationHash],
           let cost = maybeInt,
           cost > 0, cost < 255 {
            stampCostValue = .int(Int64(cost))
        } else {
            stampCostValue = .nil
        }

        // Supported functionality flags (Python: peer_data[2] = [SF_COMPRESSION])
        let supportedFunctionality: MsgPack.Value = .array([.uint(UInt64(SF_COMPRESSION))])

        return MsgPack.encode(.array([displayNameValue, stampCostValue, supportedFunctionality]))
    }

    /// Build the msgpack announce app data for the propagation destination.
    ///
    /// Format: `[False, timestamp, nodeState, perTransferLimit, perSyncLimit, [stampCost, flexibility, peeringCost], metadata]`
    ///
    /// Mirrors Python's `LXMRouter.get_propagation_node_app_data()`.
    public func getPropagationNodeAppData() -> Data {
        let ts = Int64(Date().timeIntervalSince1970)
        let nodeState = isPropagationNode
        // Python validation requires int(data[3]) and int(data[4]) to succeed — nil is rejected.
        // Use Python's default PROPAGATION_LIMIT=256 and SYNC_LIMIT=10240 when unset.
        let perTransferLimit: MsgPack.Value = .int(Int64(propagationPerTransferLimit ?? 256))
        let perSyncLimit: MsgPack.Value     = .int(Int64(propagationPerSyncLimit ?? 10240))
        let stampCostArr: MsgPack.Value = .array([
            .int(Int64(propagationStampCost)),
            .int(Int64(propagationStampCostFlexibility)),
            .int(Int64(peeringCost))
        ])
        let metaMap: MsgPack.Value = .map([])  // name and other metadata can be added via subclass/config
        return MsgPack.encode(.array([
            .bool(false),           // 0: legacy PN support flag
            .int(ts),               // 1: current timebase
            .bool(nodeState),       // 2: node active flag
            perTransferLimit,       // 3: per-transfer limit (KB or nil)
            perSyncLimit,           // 4: per-sync limit (KB or nil)
            stampCostArr,           // 5: [stampCost, flexibility, peeringCost]
            metaMap                 // 6: node metadata dict
        ]))
    }

    /// Announce the propagation destination with current app data.
    ///
    /// Mirrors Python's `LXMRouter.announce_propagation_node()`.
    @discardableResult
    public func announcePropagationNode(attachedInterface: (any Interface)? = nil) throws -> PacketReceipt? {
        guard let propDest = propagationDestination else { return nil }
        let appData = getPropagationNodeAppData()
        return try propDest.announce(appData: appData, attachedInterface: attachedInterface)
    }

    /// Announce a registered delivery destination with the current app data.
    ///
    /// A no-op if `destinationHash` is not registered.
    ///
    /// Mirrors Python's `LXMRouter.announce(destination_hash, attached_interface=None)`.
    public func announce(destinationHash: Data,
                         attachedInterface: (any Interface)? = nil) throws {
        lock.lock()
        let dest = deliveryDestinations[destinationHash]
        lock.unlock()
        guard let dest else { return }
        let appData = getAnnounceAppData(destinationHash: destinationHash)
        _ = try dest.announce(appData: appData, attachedInterface: attachedInterface)
    }

    /// Returns `true` if an active direct delivery link exists to `destinationHash`.
    ///
    /// Mirrors Python's `LXMRouter.delivery_link_available(destination_hash)`.
    public func deliveryLinkAvailable(destinationHash: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return directLinks[destinationHash] != nil
    }

    /// Returns the stamp cost required by the configured outbound propagation node,
    /// or `nil` if the cost cannot be determined from cached announce data.
    ///
    /// This is the synchronous variant: it reads from `Identity.recallAppData` only.
    /// If no app data has been cached yet, the caller should request a path to the
    /// propagation node and retry later.
    ///
    /// Mirrors the cached-read path of Python's `LXMRouter.get_outbound_propagation_cost()`.
    public func getOutboundPropagationCost() -> Int? {
        guard let pnHash = outboundPropagationNode else { return nil }
        let appData = Identity.recallAppData(forDestination: pnHash)
        return pnStampCostFromAppData(appData)
    }

    // MARK: - Ticket API

    /// Store an outbound ticket received from a remote router.
    ///
    /// Mirrors Python's `LXMRouter.remember_ticket(destination_hash, ticket_entry)`.
    ///
    /// - Parameters:
    ///   - destinationHash: The destination whose router issued this ticket.
    ///   - expiry: Absolute Unix timestamp when the ticket expires.
    ///   - ticket: The raw ticket bytes (`LXMessage.ticketLength` = 16 bytes).
    public func rememberTicket(destinationHash: Data,
                               expiry: TimeInterval,
                               ticket: Data) {
        lock.lock()
        outboundTickets[destinationHash] = (expiry: expiry, ticket: ticket)
        lock.unlock()
        saveAvailableTickets()   // persist across restarts
    }

    /// Return a valid outbound ticket for `destinationHash`, or `nil` if none exists
    /// or the stored ticket has expired.
    ///
    /// Mirrors Python's `LXMRouter.get_outbound_ticket(destination_hash)`.
    public func getOutboundTicket(destinationHash: Data) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = outboundTickets[destinationHash],
              entry.expiry > Date().timeIntervalSince1970 else { return nil }
        return entry.ticket
    }

    /// Return the expiry timestamp of the stored outbound ticket for `destinationHash`,
    /// or `nil` if no valid ticket exists.
    ///
    /// Mirrors Python's `LXMRouter.get_outbound_ticket_expiry(destination_hash)`.
    public func getOutboundTicketExpiry(destinationHash: Data) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = outboundTickets[destinationHash],
              entry.expiry > Date().timeIntervalSince1970 else { return nil }
        return entry.expiry
    }

    /// Generate (or reuse) an inbound ticket for `destinationHash` with `expiry` seconds
    /// of validity. Returns `(expiry, ticket)` or `nil` if a ticket was recently delivered.
    ///
    /// Reuses an existing ticket when it has more than `LXMessage.ticketRenew` seconds left.
    ///
    /// Mirrors Python's `LXMRouter.generate_ticket(destination_hash, expiry)`.
    @discardableResult
    public func generateTicket(destinationHash: Data,
                               expiry: TimeInterval = LXMessage.ticketExpiry)
        -> (expiry: TimeInterval, ticket: Data)? {
        // Note: manual unlock (not `defer`) so a new ticket can be persisted
        // outside the lock — `NSLock` is not reentrant and `saveAvailableTickets`
        // reacquires it.
        lock.lock()
        let now = Date().timeIntervalSince1970

        // Respect the minimum interval between ticket deliveries.
        if let lastDelivery = lastDeliveries[destinationHash],
           (now - lastDelivery) < LXMessage.ticketInterval {
            lock.unlock(); return nil
        }

        // Reuse an existing inbound ticket if it has enough validity remaining.
        if let existing = inboundTickets_[destinationHash] {
            for (ticket, ticketExpiry) in existing {
                let validityLeft = ticketExpiry - now
                if validityLeft > LXMessage.ticketRenew {
                    lock.unlock(); return (expiry: ticketExpiry, ticket: ticket)
                }
            }
        }

        // Generate a new random ticket.
        var newTicket = Data(count: LXMessage.ticketLength)
        newTicket.withUnsafeMutableBytes {
            _ = SecRandomCopyBytes(kSecRandomDefault, LXMessage.ticketLength, $0.baseAddress!)
        }
        let newExpiry = now + expiry

        if inboundTickets_[destinationHash] == nil {
            inboundTickets_[destinationHash] = [:]
        }
        inboundTickets_[destinationHash]![newTicket] = newExpiry
        lock.unlock()
        saveAvailableTickets()   // persist the newly issued ticket across restarts
        return (expiry: newExpiry, ticket: newTicket)
    }

    /// Return the list of valid inbound tickets for `destinationHash`, or `nil` if none.
    ///
    /// Mirrors Python's `LXMRouter.get_inbound_tickets(destination_hash)`.
    public func getInboundTickets(destinationHash: Data) -> [Data]? {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        guard let tickets = inboundTickets_[destinationHash] else { return nil }
        let valid = tickets.compactMap { (ticket, expiry) -> Data? in
            expiry > now ? ticket : nil
        }
        return valid.isEmpty ? nil : valid
    }

    /// Sweep expired tickets from both outbound and inbound stores.
    ///
    /// Outbound: remove if `expiry < now`.
    /// Inbound: remove if `expiry + ticketGrace < now`.
    ///
    /// Mirrors Python's `LXMRouter.clean_available_tickets()`.
    public func cleanAvailableTickets() {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970

        // Clean outbound tickets
        outboundTickets = outboundTickets.filter { $0.value.expiry > now }

        // Clean inbound tickets (respects grace period)
        for (destHash, tickets) in inboundTickets_ {
            inboundTickets_[destHash] = tickets.filter { $0.value + LXMessage.ticketGrace > now }
        }
    }

    // MARK: - Authentication API

    /// Returns whether authentication is required for inbound messages.
    /// Mirrors Python's `LXMRouter.requires_authentication()`.
    public func requiresAuthentication() -> Bool { authRequired }

    /// Set whether authentication is required.
    /// Mirrors Python's `LXMRouter.set_authentication(required)`.
    public func setAuthentication(required: Bool) { authRequired = required }

    /// Add an identity hash to the allow-list.
    /// Mirrors Python's `LXMRouter.allow(identity_hash)`.
    public func allow(identityHash: Data) {
        lock.lock(); defer { lock.unlock() }
        allowedList.insert(identityHash)
    }

    /// Remove an identity hash from the allow-list.
    /// Mirrors Python's `LXMRouter.disallow(identity_hash)`.
    public func disallow(identityHash: Data) {
        lock.lock(); defer { lock.unlock() }
        allowedList.remove(identityHash)
    }

    /// Returns `true` if the given hash is on the allow-list.
    public func isAllowed(identityHash: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return allowedList.contains(identityHash)
    }

    // MARK: - Stamp cost management

    /// Store per-destination inbound stamp cost.
    /// Mirrors Python's `LXMRouter.set_inbound_stamp_cost(destination_hash, stamp_cost)`.
    @discardableResult
    public func setInboundStampCost(destinationHash: Data, stampCost: Int?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        inboundStampCosts[destinationHash] = stampCost
        return true
    }

    /// Return the outbound stamp cost for a destination, or `nil` if unknown.
    /// Mirrors Python's `LXMRouter.get_outbound_stamp_cost(destination_hash)`.
    public func getOutboundStampCost(destinationHash: Data) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return outboundStampCosts[destinationHash]
    }

    /// Store outbound stamp cost learned from an announce or path response.
    public func setOutboundStampCost(destinationHash: Data, stampCost: Int) {
        lock.lock()
        outboundStampCosts[destinationHash] = stampCost
        lock.unlock()
        saveOutboundStampCosts()   // persist across restarts
    }

    // MARK: - Priority list API

    /// Add a destination hash to the priority delivery list.
    /// Mirrors Python's `LXMRouter.prioritise(destination_hash)`.
    public func prioritise(destinationHash: Data) {
        if !prioritisedList.contains(destinationHash) { prioritisedList.append(destinationHash) }
    }

    /// Remove a destination hash from the priority delivery list.
    /// Mirrors Python's `LXMRouter.unprioritise(destination_hash)`.
    public func unprioritise(destinationHash: Data) {
        prioritisedList.removeAll { $0 == destinationHash }
    }

    /// Returns `true` if the given destination hash is on the priority list.
    public func isPrioritised(destinationHash: Data) -> Bool {
        prioritisedList.contains(destinationHash)
    }

    // MARK: - Stamp enforcement API

    /// Enable stamp enforcement for inbound messages.
    /// Mirrors Python's `LXMRouter.enforce_stamps()`.
    public func enforceStamps() { enforceStamps_ = true }

    /// Disable stamp enforcement for inbound messages.
    /// Mirrors Python's `LXMRouter.ignore_stamps()`.
    public func ignoreStamps()  { enforceStamps_ = false }

    /// Returns whether stamp enforcement is currently active.
    public func isEnforcingStamps() -> Bool { enforceStamps_ }

    // MARK: - Ignore list API

    /// Add a destination hash to the ignore list (inbound messages are silently dropped).
    /// Mirrors Python's `LXMRouter.ignore(destination_hash)`.
    public func ignoreDestination(destinationHash: Data) {
        if !ignoredList.contains(destinationHash) { ignoredList.append(destinationHash) }
    }

    /// Remove a destination hash from the ignore list.
    /// Mirrors Python's `LXMRouter.unignore(destination_hash)`.
    public func unignoreDestination(destinationHash: Data) {
        ignoredList.removeAll { $0 == destinationHash }
    }

    /// Returns `true` if the given destination hash is on the ignore list.
    public func isIgnoringDestination(destinationHash: Data) -> Bool {
        ignoredList.contains(destinationHash)
    }

    // MARK: - Message lifecycle

    /// Returns `true` if a message with the given transient ID has been delivered locally.
    /// Mirrors Python's `LXMRouter.has_message(transient_id)`.
    public func hasMessage(transientID: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return locallyDeliveredTransientIDs[transientID] != nil
    }

    // MARK: - Inbound message resource transfers
    //
    // A large inbound message arrives as a Resource, which can take a long time
    // over a slow or multi-hop path. Tracking the in-flight transfers lets a UI
    // show what is arriving and lets the user abort one that is unwanted or
    // oversized, rather than being forced to wait it out.
    // Mirrors Python LXMF 1.1.0 (commit d909619).

    /// Whether a transfer is still running (Python's `status < RNS.Resource.COMPLETE`).
    private static func isActive(_ transfer: ResourceTransfer) -> Bool {
        switch transfer.status {
        case .complete, .rejected, .failed: return false
        default:                            return true
        }
    }

    /// Record an inbound delivery resource as it starts transferring.
    /// Mirrors Python's `delivery_resource_transfer_began`.
    private func trackIncomingDeliveryResource(_ transfer: ResourceTransfer) {
        incomingDeliveryResourceLock.lock()
        incomingDeliveryResources[transfer.resourceHash] = transfer
        incomingDeliveryResourceLock.unlock()
    }

    /// The keys currently in the in-flight registry, snapshot under the lock.
    /// Test hook: `inboundResources()` filters to active transfers and so cannot
    /// tell "two transfers filed under one key" apart from "one transfer".
    func inboundRegistryKeys() -> [Data] {
        incomingDeliveryResourceLock.lock(); defer { incomingDeliveryResourceLock.unlock() }
        return Array(incomingDeliveryResources.keys)
    }

    /// Drop concluded entries from the in-flight registry. Without this the
    /// registry grows for the lifetime of the router.
    /// Mirrors Python's `LXMRouter.clean_resource_tracking()`.
    func cleanResourceTracking() {
        incomingDeliveryResourceLock.lock()
        for (hash, transfer) in incomingDeliveryResources where !LXMRouter.isActive(transfer) {
            incomingDeliveryResources.removeValue(forKey: hash)
        }
        incomingDeliveryResourceLock.unlock()
    }

    /// Number of inbound message transfers currently in progress.
    /// Mirrors Python's `LXMRouter.inbound_count()`.
    public func inboundCount() -> Int {
        incomingDeliveryResourceLock.lock(); defer { incomingDeliveryResourceLock.unlock() }
        return incomingDeliveryResources.values.filter(LXMRouter.isActive).count
    }

    /// The inbound message transfers currently in progress.
    /// Mirrors Python's `LXMRouter.inbound_resources()`.
    public func inboundResources() -> [ResourceTransfer] {
        incomingDeliveryResourceLock.lock(); defer { incomingDeliveryResourceLock.unlock() }
        return incomingDeliveryResources.values.filter(LXMRouter.isActive)
    }

    /// Cancel one in-flight inbound message transfer.
    /// - Returns: `true` if a running transfer was cancelled; `false` if it is
    ///   unknown or already concluded.
    /// Mirrors Python's `LXMRouter.cancel_inbound(resource_hash)`.
    @discardableResult
    public func cancelInbound(resourceHash: Data) -> Bool {
        incomingDeliveryResourceLock.lock()
        let transfer = incomingDeliveryResources[resourceHash]
        incomingDeliveryResourceLock.unlock()
        guard let transfer else { return false }
        guard LXMRouter.isActive(transfer) else { return false }
        // cancel() is called outside the lock: it reaches into the link to emit
        // a cancel packet and may re-enter our own resource callbacks.
        transfer.cancel()
        return true
    }

    /// Cancel every in-flight inbound message transfer.
    /// - Returns: how many were cancelled.
    /// Mirrors Python's `LXMRouter.cancel_all_inbound()`.
    @discardableResult
    public func cancelAllInbound() -> Int {
        let active = inboundResources()
        for transfer in active { transfer.cancel() }
        return active.count
    }

    /// Cancel a pending outbound message by its `messageID`.
    /// Sets state to `.cancelled` and removes it from the pending queue.
    /// Mirrors Python's `LXMRouter.cancel_outbound(message_id)`.
    public func cancelOutbound(messageID: Data) {
        lock.lock()
        if let idx = pendingOutbound.firstIndex(where: { $0.messageID == messageID }) {
            pendingOutbound[idx].state = .cancelled
        }
        pendingOutbound.removeAll { $0.messageID == messageID && $0.state == .cancelled }
        lock.unlock()
    }

    /// Returns the delivery progress (0.0–1.0) for a pending message identified by hash,
    /// or `nil` if no such message is pending.
    /// Mirrors Python's `LXMRouter.get_outbound_progress(lxm_hash)`.
    public func getOutboundProgress(lxmHash: Data) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return pendingOutbound.first { $0.hash == lxmHash }?.progress
    }

    // MARK: - URI ingestion

    /// Decode a `lxm://` URI and deliver the contained message locally.
    ///
    /// Mirrors Python's `LXMRouter.ingest_lxm_uri(uri)` (`LXMRouter.py:2542-2562`), which
    /// hands the decoded bytes to `lxmf_propagation(..., is_paper_message=True)` and so
    /// down the same `lxmf_delivery` path as every other inbound route: the payload is
    /// decrypted with the addressed delivery destination (`:2503-2504`), and ticket
    /// ingest, the ignore list and duplicate suppression all apply. Stamp enforcement is
    /// waived for paper messages (`:2489`, `is_paper_message → no_stamp_enforcement`).
    ///
    /// Calling the application callback directly instead — as this did — skipped all of
    /// it, so an ignored sender's paper message was delivered and a re-scanned QR was
    /// delivered twice (`bugs/026`).
    ///
    /// - Returns: `true` when the message was delivered to the application, `false` when
    ///   the inbound path dropped it (ignored sender, duplicate, failed stamp).
    /// - Throws: `invalidURI` for a malformed or wrong-scheme URI,
    ///   `noMatchingDeliveryDestination` when the message is addressed to a destination
    ///   this router does not host, `paperDecryptionFailed` when it cannot be decrypted.
    @discardableResult
    public func ingestLXMURI(_ uri: String) throws -> Bool {
        let paperData = try LXMessage.paperData(fromURI: uri)
        let destHash  = Data(paperData.prefix(LXMessage.destinationLength))
        let ciphertext = Data(paperData.dropFirst(LXMessage.destinationLength))

        lock.lock(); let destination = deliveryDestinations[destHash]; lock.unlock()
        guard let destination else {
            // Python returns True here having done nothing (it would queue the message for
            // propagation, which a paper message never is). Reporting a failure the caller
            // can act on is the point of this change — a scanned QR addressed elsewhere is
            // not an ingest that succeeded.
            throw LXMessage.LXMessageError.noMatchingDeliveryDestination
        }
        guard let plaintext = try? destination.decrypt(ciphertext) else {
            throw LXMessage.LXMessageError.paperDecryptionFailed
        }

        return deliverInboundResource(destHash + plaintext, noStampEnforcement: true)
    }

    // MARK: - Outbound

    /// Enqueue a message for delivery. Call `processOutbound()` to attempt
    /// sending, or set up a periodic timer to drive delivery retries.
    ///
    /// Throws an `IOError` if the message's desired method is `.propagated` but
    /// no `outboundPropagationNode` is configured.
    /// Mirrors Python `LXMRouter.handle_outbound()` guard added in 0.9.9.
    public func send(_ message: LXMessage) throws {
        if message.desiredMethod == .propagated && outboundPropagationNode == nil {
            message.state = .failed
            throw LXMRouterError.noPropagationNode
        }

        // Wire in stored outbound ticket before packing so the cheap ticket stamp
        // is used instead of proof-of-work.
        // Mirrors Python: lxmessage.outbound_ticket = self.get_outbound_ticket(destination_hash)
        if message.packed == nil {
            let destHash = message.destinationHash

            // Auto-configure stamp cost from stored announce data if not already set.
            // Mirrors Python handle_outbound() lines 1651-1655.
            if message.stampCost == nil, let cost = getOutboundStampCost(destinationHash: destHash) {
                message.stampCost = cost
            }

            if let ticket = getOutboundTicket(destinationHash: destHash) {
                message.outboundTicket = ticket
            }

            // If requested, generate an inbound ticket and attach it to the message fields
            // so the recipient can reply without generating a stamp.
            // Mirrors Python: if lxmessage.include_ticket → self.generate_ticket(dest) → fields[FIELD_TICKET]
            if message.includeTicket {
                if let entry = generateTicket(destinationHash: destHash) {
                    let ticketFieldKey = Int(Field.ticket.rawValue)
                    message.fields[ticketFieldKey] = [entry.expiry, entry.ticket] as [Any]
                }
            }

            try message.pack()

            // For PROPAGATED messages, generate the PN stamp on a background thread
            // (mirrors Python's defer_propagation_stamp=True behavior) so the caller's
            // thread (typically the main RunLoop) is not blocked by PoW for cost=16+.
            if message.desiredMethod == .propagated {
                let cost = getOutboundPropagationCost() ?? 0
                message.state = .outbound
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    message.attachPropagationStamp(cost: cost)
                    guard let self else { return }
                    self.lock.lock(); self.pendingOutbound.append(message); self.lock.unlock()
                    self.processOutbound()
                }
                return
            }
        }

        message.state = .outbound
        lock.lock(); pendingOutbound.append(message); lock.unlock()
        processOutbound()
    }

    /// Drive the outbound delivery queue. Safe to call from any thread.
    /// Mirrors Python's `LXMRouter.process_outbound()`.
    public func processOutbound() {
        lock.lock()
        let snapshot = pendingOutbound
        lock.unlock()

        for msg in snapshot {
            switch msg.state {
            case .delivered, .sent:
                removePending(msg)
                msg.onDelivery?(msg)
            case .rejected, .cancelled:
                removePending(msg)
                msg.onFailed?(msg)
            case .failed:
                removePending(msg)
                msg.onFailed?(msg)
            case .outbound, .sending:
                attemptDelivery(msg)
            default:
                break
            }
        }
    }

    private func attemptDelivery(_ msg: LXMessage) {
        let now = Date().timeIntervalSince1970
        guard now >= msg.nextDeliveryAttempt else { return }

        switch msg.method {
        case .opportunistic:
            deliverOpportunistically(msg)
        case .direct, .unknown:
            deliverDirect(msg)
        case .propagated:
            deliverPropagated(msg)
        default:
            break
        }
    }

    // MARK: - Opportunistic delivery

    private func deliverOpportunistically(_ msg: LXMessage) {
        let destHash = msg.destinationHash

        if msg.deliveryAttempts >= LXMRouter.maxPathlessTries && !transport.hasPath(to: destHash) {
            try? transport.requestPath(for: destHash)
            msg.deliveryAttempts += 1
            msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.pathRequestWait
            return
        }

        if msg.deliveryAttempts >= LXMRouter.maxDeliveryAttempts {
            msg.state = .failed
            return
        }

        guard let identity = transport.recall(identity: destHash),
              let packed = msg.packed else {
            msg.deliveryAttempts += 1
            msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
            return
        }

        msg.deliveryAttempts += 1
        msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
        msg.state = .sending

        // For opportunistic delivery the packet body omits the leading
        // destination hash (the packet's destination_hash field already
        // carries it). Mirrors Python: `packed[DESTINATION_LENGTH:]`.
        let body = packed.dropFirst(LXMessage.destinationLength)

        do {
            // Encrypt to the destination identity (using ratchet if known).
            let ratchet = transport.knownRatchets[destHash]
            let ciphertext = try identity.encrypt(Data(body), ratchetPublicKey: ratchet)
            let packet = Packet(
                destinationType: .single,
                packetType: .data,
                destinationHash: destHash,
                data: ciphertext
            )
            try transport.send(packet)
            msg.state = .sent
        } catch {
            msg.state = .outbound
        }
    }

    // MARK: - Direct delivery

    private func deliverDirect(_ msg: LXMessage) {
        let destHash = msg.destinationHash

        if msg.deliveryAttempts >= LXMRouter.maxDeliveryAttempts {
            msg.state = .failed
            return
        }

        lock.lock()
        let existingLink = directLinks[destHash]
        lock.unlock()

        if let link = existingLink {
            switch link.status {
            case .active:
                sendOverLink(msg, link: link)
            case .closed, .failed, .stale:
                // Link died — open a new one after requesting the path.
                lock.lock(); directLinks.removeValue(forKey: destHash); lock.unlock()
                try? transport.requestPath(for: destHash)
                msg.deliveryAttempts += 1
                msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.pathRequestWait
            case .pending, .handshake:
                break // still establishing, wait
            }
            return
        }

        // No link — check for a path and open one.
        guard transport.hasPath(to: destHash) else {
            try? transport.requestPath(for: destHash)
            msg.deliveryAttempts += 1
            msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.pathRequestWait
            return
        }

        guard let identity = transport.recall(identity: destHash) else { return }
        guard let destination = try? Destination(
            identity: identity,
            direction: .out,
            kind: .single,
            appName: APP_NAME,
            aspects: ["delivery"]
        ) else { return }

        do {
            let link = try Link.initiate(destination: destination, transport: transport)
            lock.lock(); directLinks[destHash] = link; lock.unlock()

            link.onEstablished = { [weak self] l in
                self?.sendOverLink(msg, link: l)
            }
            link.onClosed = { [weak self] _ in
                self?.lock.lock()
                self?.directLinks.removeValue(forKey: destHash)
                self?.lock.unlock()
            }
        } catch {
            msg.deliveryAttempts += 1
            msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
        }
    }

    // MARK: - Propagated delivery

    private func deliverPropagated(_ msg: LXMessage) {
        guard let nodeHash = outboundPropagationNode else {
            removePending(msg)
            msg.state = .failed
            msg.onFailed?(msg)
            return
        }

        if msg.deliveryAttempts >= LXMRouter.maxDeliveryAttempts {
            removePending(msg)
            msg.state = .failed
            msg.onFailed?(msg)
            return
        }

        lock.lock()
        let existingLink = outboundPropagationLink
        lock.unlock()

        if let link = existingLink {
            switch link.status {
            case .active:
                sendPropagatedOverLink(msg, link: link)
            case .closed, .failed, .stale:
                lock.lock(); outboundPropagationLink = nil; lock.unlock()
                msg.deliveryAttempts += 1
                msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
            case .pending, .handshake:
                break
            }
            return
        }

        guard transport.hasPath(to: nodeHash) else {
            try? transport.requestPath(for: nodeHash)
            msg.deliveryAttempts += 1
            msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.pathRequestWait
            return
        }

        guard let nodeIdentity = transport.recall(identity: nodeHash),
              let nodeDest = try? Destination(
                  identity: nodeIdentity, direction: .out, kind: .single,
                  appName: APP_NAME, aspects: ["propagation"]
              ) else {
            msg.deliveryAttempts += 1
            msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
            return
        }

        do {
            let link = try Link.initiate(destination: nodeDest, transport: transport)
            lock.lock(); outboundPropagationLink = link; lock.unlock()
            link.onEstablished = { [weak self] l in
                self?.sendPropagatedOverLink(msg, link: l)
            }
            link.onClosed = { [weak self] _ in
                self?.lock.lock()
                self?.outboundPropagationLink = nil
                self?.lock.unlock()
            }
        } catch {
            msg.deliveryAttempts += 1
            msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
        }
    }

    private func sendPropagatedOverLink(_ msg: LXMessage, link: Link) {
        guard msg.state != .sending else { return }
        guard let pp = msg.propagationPacked else { return }
        msg.state = .sending
        let transfer = ResourceTransfer(link: link)
        transfer.onComplete = { [weak self, weak msg] _ in
            guard let msg else { return }
            self?.removePending(msg)
            msg.state = .delivered
            // Retain destination announce data (LXMF commit 8bdb434).
            _ = self?.transport.retainDestinationData(msg.destinationHash)
            msg.onDelivery?(msg)
        }
        transfer.onFailed = { [weak self, weak msg] _, _ in
            guard let msg else { return }
            self?.removePending(msg)
            msg.state = .failed
            msg.onFailed?(msg)
        }
        do {
            try transfer.send(payload: pp)
        } catch {
            msg.state = .outbound
            msg.deliveryAttempts += 1
            msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
        }
    }

    private func sendOverLink(_ msg: LXMessage, link: Link) {
        guard msg.state != .sending else { return }
        guard let packed = msg.packed else { return }

        if msg.representation == .resource {
            // Large message: send as Resource. The resource carries the FULL packed bytes
            // (including the leading destination hash) — matches Python LXMessage.__as_resource().
            msg.state = .sending
            let transfer = ResourceTransfer(link: link)
            transfer.onComplete = { [weak self, weak msg] _ in
                guard let msg else { return }
                self?.removePending(msg)
                msg.state = .delivered
                // Retain destination announce data (LXMF commit 8bdb434).
                _ = self?.transport.retainDestinationData(msg.destinationHash)
                msg.onDelivery?(msg)
            }
            transfer.onFailed = { [weak self, weak msg] _, _ in
                guard let msg else { return }
                self?.removePending(msg)
                msg.state = .failed
                msg.onFailed?(msg)
            }
            do {
                try transfer.send(payload: packed)
            } catch {
                msg.state = .outbound
                msg.deliveryAttempts += 1
                msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
            }
        } else {
            // Small message: send as a single link packet.
            // Python DIRECT delivery sends the FULL packed bytes (destHash included).
            // Mirrors Python LXMessage.__as_packet(): `RNS.Packet(delivery_dest, self.packed)`.
            //
            // `bugs/014`. This used to set `.delivered` and fire `onDelivery` on the line after
            // `link.send(...)` returned. Returning from a send call means the bytes were handed
            // to an interface, not that anyone received them — so a message dropped by the very
            // next hop was reported delivered, and the recipient never saw it. The reference
            // reaches DELIVERED only from the receipt's delivery callback
            // (`LXMessage.py:479-483`, `__mark_delivered` at `:563-568`).
            msg.state = .sending
            do {
                let receipt = try link.send(packed)

                guard let receipt else {
                    // Python tears the delivery destination down when no receipt came back
                    // (`LXMessage.py:484-486`) — without one there is no way to ever learn
                    // whether the message arrived, so the link is not worth keeping.
                    try? link.teardown()
                    msg.state = .outbound
                    msg.deliveryAttempts += 1
                    msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
                    return
                }

                msg.deliveryReceipt = receipt
                msg.progress = 0.50

                receipt.onDelivery = { [weak self, weak msg] _ in
                    guard let self, let msg else { return }
                    // Removed from the queue before the state flips, so a concurrent
                    // `processOutbound` cannot see a delivered message still pending and fire
                    // the application callback a second time.
                    self.removePending(msg)
                    msg.state = .delivered
                    msg.progress = 1.0
                    // Retain destination announce data (LXMF commit 8bdb434).
                    _ = self.transport.retainDestinationData(msg.destinationHash)
                    msg.onDelivery?(msg)
                }

                receipt.onTimeout = { [weak msg] _ in
                    guard let msg, msg.state != .cancelled else { return }
                    // Python tears the link down and returns the message to OUTBOUND for
                    // another attempt (`__link_packet_timed_out`, `LXMessage.py:616-621`). The
                    // link is torn down because a proof that never came back is evidence about
                    // the link, not just about this packet.
                    try? link.teardown()
                    msg.state = .outbound
                    msg.progress = 0
                    msg.deliveryAttempts += 1
                    msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
                }
            } catch {
                msg.state = .outbound
                msg.deliveryAttempts += 1
                msg.nextDeliveryAttempt = Date().timeIntervalSince1970 + LXMRouter.deliveryRetryWait
            }
        }
    }

    // MARK: - Propagation sync (inbound)

    /// Request messages from the configured propagation node.
    /// Establishes a link if not already active; requests a path if needed.
    /// Mirrors Python `LXMRouter.request_messages_from_propagation_node()`.
    public func requestMessagesFromPropagationNode(identity: Identity, maxMessages: Int? = nil) {
        propagationTransferProgress = 0.0
        propagationTransferSize = nil
        propagationTransferMaxMessages = maxMessages

        guard let nodeHash = outboundPropagationNode else { return }

        lock.lock()
        let existingLink = outboundPropagationLink
        lock.unlock()

        if let link = existingLink, link.status == .active {
            propagationTransferState = .linkEstablished
            try? link.identify(as: identity)
            // [nil, nil] = "give me everything" (want=nil, have=nil) — use nativeValue:
            // so Python propagation nodes receive a native msgpack array, not bytes.
            _ = try? link.request(
                path: LXMPeer.messageGetPath,
                nativeValue: .array([.nil, .nil]),
                responseCallback: { [weak self] data, receipt in
                    self?.handleMessageListResponse(data, receipt: receipt)
                },
                failedCallback: { [weak self] _, receipt in
                    self?.handleMessageGetFailed(receipt)
                }
            )
            propagationTransferState = .requestSent

        } else if existingLink == nil {
            if transport.hasPath(to: nodeHash) {
                guard let nodeIdentity = transport.recall(identity: nodeHash) else { return }
                guard let nodeDest = try? Destination(
                    identity: nodeIdentity,
                    direction: .out,
                    kind: .single,
                    appName: APP_NAME,
                    aspects: ["propagation"]
                ) else { return }
                propagationTransferState = .linkEstablishing
                guard let link = try? Link.initiate(destination: nodeDest, transport: transport) else {
                    propagationTransferState = .idle
                    return
                }
                lock.lock(); outboundPropagationLink = link; lock.unlock()
                link.onEstablished = { [weak self] _ in
                    self?.requestMessagesFromPropagationNode(identity: identity, maxMessages: maxMessages)
                }
                link.onClosed = { [weak self] _ in
                    self?.lock.lock()
                    self?.outboundPropagationLink = nil
                    self?.lock.unlock()
                }
            } else {
                propagationTransferState = .pathRequested
                wantsDownloadOnPathAvailableFrom = nodeHash
                try? transport.requestPath(for: nodeHash)
            }
        }
        // else: link is establishing — wait for onEstablished callback
    }

    /// Cancel any in-progress propagation sync, tear down the link, and reset state.
    /// Mirrors Python `LXMRouter.cancel_propagation_node_requests()`.
    public func cancelPropagationNodeRequests() {
        lock.lock()
        let link = outboundPropagationLink
        outboundPropagationLink = nil
        lock.unlock()
        try? link?.teardown()
        propagationTransferState = .idle
        propagationTransferProgress = 0.0
        propagationTransferSize = nil
        wantsDownloadOnPathAvailableFrom = nil
    }

    func handleMessageListResponse(_ data: Data, receipt: RequestReceipt) {
        guard let decoded = try? MsgPack.decode(data) else {
            lock.lock(); let link = outboundPropagationLink; lock.unlock()
            try? link?.teardown()
            propagationTransferState = .failed
            return
        }

        // Specific error codes from the propagation node (encoded as uint by Python)
        if isPeerError(decoded) {
            lock.lock(); let link = outboundPropagationLink; lock.unlock()
            try? link?.teardown()
            propagationTransferState = .failed
            return
        }

        guard case .array(let idValues) = decoded else {
            lock.lock(); let link = outboundPropagationLink; lock.unlock()
            try? link?.teardown()
            propagationTransferState = .failed
            return
        }

        let availableIDs = idValues.compactMap { v -> Data? in
            if case .bytes(let b) = v { return Data(b) }
            return nil
        }

        if availableIDs.isEmpty {
            propagationTransferState = .done
            propagationTransferProgress = 1.0
            return
        }

        var wants: [Data] = []
        var haves: [Data] = []
        let maxMessages = propagationTransferMaxMessages

        for tid in availableIDs {
            if hasMessage(transientID: tid) {
                if !retainSyncedOnNode { haves.append(tid) }
            } else {
                if maxMessages == nil || wants.count < maxMessages! { wants.append(tid) }
            }
        }

        let wantsValue: MsgPack.Value = wants.isEmpty ? .nil : .array(wants.map { .bytes($0) })
        let havesValue: MsgPack.Value = haves.isEmpty ? .nil : .array(haves.map { .bytes($0) })
        let limitValue: MsgPack.Value = deliveryPerTransferLimit.map { .int(Int64($0)) } ?? .nil

        lock.lock(); let link = outboundPropagationLink; lock.unlock()
        guard let link else { propagationTransferState = .failed; return }

        propagationTransferState = .receiving
        _ = try? link.request(
            path: LXMPeer.messageGetPath,
            nativeValue: .array([wantsValue, havesValue, limitValue]),
            responseCallback: { [weak self] responseData, receipt in
                self?.handleMessageGetResponse(responseData, receipt: receipt)
            },
            failedCallback: { [weak self] _, receipt in
                self?.handleMessageGetFailed(receipt)
            },
            progressCallback: { [weak self] progress, receipt in
                self?.messageGetProgress(progress, receipt: receipt)
            }
        )
    }

    /// Track a running message-get transfer so a UI can render live progress and
    /// the total transfer size while the response resource is still arriving.
    ///
    /// Only this request carries a progress callback — Python attaches
    /// `progress_callback=self.message_get_progress` to the message *fetch*
    /// (LXMRouter.py:1590-1595) and to neither the initial list request nor the
    /// receipt-confirmation request. Without it `propagationTransferSize` was
    /// only readable once the whole transfer had already finished, which is
    /// exactly when a progress display no longer needs it.
    /// Mirrors Python's `LXMRouter.message_get_progress(request_receipt)`.
    func messageGetProgress(_ progress: Double, receipt: RequestReceipt) {
        propagationTransferState = .receiving
        propagationTransferProgress = progress
        // Python guards with a truthy test (`if request_receipt.response_size:`),
        // so a zero never replaces a previously known size.
        if let size = receipt.responseSize, size > 0 { propagationTransferSize = size }
    }

    /// Clear a finished sync's transient result state, so a UI that has shown the
    /// outcome can dismiss it and the next sync starts clean.
    ///
    /// - Parameters:
    ///   - resetState: also reset a *failed* sync's state. By default a failure is
    ///     left in place so it stays visible until explicitly acknowledged.
    ///   - failureState: state to move to instead of `.idle`.
    ///
    /// Without this, `propagationTransferSize` survived a successful sync and the
    /// next one showed the previous transfer's size until its first progress
    /// callback landed. (Python additionally clears
    /// `propagation_transfer_last_result` and `wants_download_on_path_available_to`;
    /// neither field exists here.)
    /// Mirrors Python's `LXMRouter.acknowledge_sync_completion(reset_state, failure_state)`.
    public func acknowledgeSyncCompletion(resetState: Bool = false,
                                          failureState: PropagationTransferState? = nil) {
        // Python's `propagation_transfer_state <= PR_COMPLETE (0x07)` — every
        // failure code is 0xf0 or above, so this reads as "not a failure".
        if resetState || propagationTransferState != .failed {
            propagationTransferState = failureState ?? .idle
        }
        propagationTransferProgress = 0.0
        propagationTransferSize = nil
        wantsDownloadOnPathAvailableFrom = nil
    }

    func handleMessageGetResponse(_ data: Data, receipt: RequestReceipt) {
        // Python: `if request_receipt.response_size: self.propagation_transfer_size = ...`
        if let size = receipt.responseSize { propagationTransferSize = size }
        guard let decoded = try? MsgPack.decode(data) else {
            propagationTransferState = .done; propagationTransferProgress = 1.0; return
        }

        // Specific error codes from the propagation node
        if isPeerError(decoded) {
            lock.lock(); let link = outboundPropagationLink; lock.unlock()
            try? link?.teardown()
            propagationTransferState = .failed
            return
        }

        guard case .array(let msgValues) = decoded else {
            propagationTransferState = .done; propagationTransferProgress = 1.0; return
        }

        var haves: [Data] = []
        let destLen = LXMessage.destinationLength

        for value in msgValues {
            guard case .bytes(let lxmfBytes) = value, lxmfBytes.count > destLen else { continue }
            let lxmfData = Data(lxmfBytes)
            let transientID = Hashes.fullHash(lxmfData)
            haves.append(transientID)

            if hasMessage(transientID: transientID) { continue }

            let destHash = Data(lxmfData.prefix(destLen))
            let encryptedPayload = Data(lxmfData.dropFirst(destLen))

            lock.lock(); let dest = deliveryDestinations[destHash]; lock.unlock()
            guard let dest,
                  let plaintext = try? dest.decrypt(encryptedPayload) else { continue }

            lock.lock(); locallyDeliveredTransientIDs[transientID] = Date().timeIntervalSince1970; lock.unlock()
            deliverInboundResource(destHash + plaintext)
        }
        // Persist the updated delivered-id set once per sync batch (not per id).
        saveLocallyDeliveredTransientIDs()

        // Confirm receipt — propagation node deletes confirmed messages
        if !haves.isEmpty {
            lock.lock(); let link = outboundPropagationLink; lock.unlock()
            _ = try? link?.request(
                path: LXMPeer.messageGetPath,
                nativeValue: .array([.nil, .array(haves.map { .bytes($0) })]),
                failedCallback: nil
            )
        }

        propagationTransferState = .done
        propagationTransferProgress = 1.0
    }

    private func handleMessageGetFailed(_ receipt: RequestReceipt) {
        propagationTransferState = .failed
        propagationTransferSize = nil
    }

    /// Returns true if the msgpack value represents a propagation-node error code
    /// (0xF0 = noIdentity, 0xF1 = noAccess). Python encodes these as uint, so
    /// we must match both .int and .uint variants.
    private func isPeerError(_ value: MsgPack.Value) -> Bool {
        let errors: Set<UInt64> = [
            UInt64(LXMPeerError.noIdentity.rawValue),
            UInt64(LXMPeerError.noAccess.rawValue),
        ]
        switch value {
        case .int(let code) where code >= 0: return errors.contains(UInt64(code))
        case .uint(let code):                return errors.contains(code)
        default: return false
        }
    }

    // MARK: - Inbound resource messages

    /// Deliver a fully-assembled LXMF resource payload. The `data` argument is the
    /// raw bytes as received from `ResourceTransfer.onPayloadReceived` — for LXMF
    /// this is the full packed message (including leading destination hash).
    /// Called by `delivery.onLinkEstablished → link.onResourceConcluded`.
    /// - Parameter noStampEnforcement: waive stamp enforcement for a message already
    ///   validated upstream. Python sets this for paper messages
    ///   (`LXMRouter.py:2489`) and for messages fetched from a propagation node.
    /// - Returns: `true` when the message reached the application.
    @discardableResult
    public func deliverInboundResource(_ data: Data, noStampEnforcement: Bool = false) -> Bool {
        guard let msg = try? LXMessage.unpack(data) else { return false }
        // Drop messages from blackholed source identities (LXMF commit 2ac2b10).
        if msg.sourceBlackholed { return false }
        lock.lock()
        let isDelivery = deliveryDestinations[msg.destinationHash] != nil
        lock.unlock()
        guard isDelivery else { return false }
        msg.incoming = true
        msg.state = .delivered

        if let srcIdentity = transport.recall(identity: msg.sourceHash) {
            msg.validateSignature(knownIdentity: srcIdentity)
            return finalizeInboundDelivery(msg, noStampEnforcement: noStampEnforcement)
        } else {
            return deliverWithUnknownSource(msg, noStampEnforcement: noStampEnforcement)
        }
    }

    /// Notify the router that an identity for `destinationHash` has been announced.
    ///
    /// If there are inbound messages in `pendingSignatureValidation` with that
    /// `sourceHash`, they are validated with the supplied identity and delivered
    /// via `onMessageReceived`. This is a low-level hook for callers that observe
    /// announces through a separate mechanism (e.g. `transport.onAnnounceReceived`)
    /// and want to trigger deferred validation without relying on the announce
    /// handler dispatch chain.
    ///
    /// In practice, `runReceive` in `LXMFTestNode` calls this because
    /// `transport.onAnnounceReceived` is reliable whereas the aspect-filter
    /// announce handler has been observed to be pre-empted in test scenarios.
    public func notifyAnnounced(destinationHash: Data, identity: Identity) {
        lock.lock()
        let pending = pendingSignatureValidation.filter { $0.message.sourceHash == destinationHash }
        pendingSignatureValidation.removeAll { $0.message.sourceHash == destinationHash }
        lock.unlock()

        for (msg, _) in pending {
            msg.validateSignature(knownIdentity: identity)
            finalizeInboundDelivery(msg)
        }
    }

    /// Inject a pre-established link into the router's direct-link table. Useful in
    /// tests and when a caller manages link lifecycle externally.
    public func injectDirectLink(_ link: Link, for destinationHash: Data) {
        lock.lock(); directLinks[destinationHash] = link; lock.unlock()
    }

    // MARK: - Unknown-source delivery

    /// Deliver an inbound message whose source identity is not yet known.
    ///
    /// Mirrors Python `LXMessage.unpack_from_bytes` → `LXMRouter.lxmf_delivery`:
    /// when `RNS.Identity.recall(source_hash)` returns `None`, Python still
    /// builds and **delivers** the message, marking it `signature_validated =
    /// False`, `unverified_reason = SOURCE_UNKNOWN` — it does **not** hold the
    /// message back waiting for the source's announce.
    ///
    /// The previous Swift behavior *deferred* delivery until the source announce
    /// arrived (or a 60 s fallback fired). That diverged from Python and, worse,
    /// **dropped** the message whenever the source announce did not reach us
    /// within the application's receive window — the announce is forwarded on a
    /// separate backbone thread and can lag the data packet, so opportunistic
    /// delivery from a not-yet-announced sender became a race (flaky). Delivering
    /// immediately (unverified) matches Python and removes the race. Re-delivery
    /// once the announce lands is neither needed nor possible: the transient-ID
    /// dedup in `finalizeInboundDelivery` would suppress it. See swift_devel
    /// bug 006.
    @discardableResult
    private func deliverWithUnknownSource(_ msg: LXMessage, noStampEnforcement: Bool = false) -> Bool {
        if msg.unverifiedReason == nil { msg.unverifiedReason = .sourceUnknown }
        return finalizeInboundDelivery(msg, noStampEnforcement: noStampEnforcement)
    }

    // MARK: - Inbound

    private func handleInboundPacket(_ packet: Packet, destination: Destination) {
        // Only handle packets addressed to registered delivery destinations.
        lock.lock()
        let isDelivery = deliveryDestinations[packet.destinationHash] != nil
        lock.unlock()
        guard isDelivery else { return }

        guard let identity = destination.identity else { return }
        guard let plaintext = try? destination.decrypt(packet.data) else { return }

        // Prepend the destination hash that was stripped for wire-efficiency.
        let wire = destination.hash + plaintext
        guard let msg = try? LXMessage.unpack(wire) else { return }

        // Drop messages from blackholed source identities (LXMF commit 2ac2b10).
        if msg.sourceBlackholed { return }

        _ = identity  // suppress unused warning
        msg.incoming = true
        msg.state = .delivered

        if let srcIdentity = transport.recall(identity: msg.sourceHash) {
            msg.validateSignature(knownIdentity: srcIdentity)
            finalizeInboundDelivery(msg)
        } else {
            // Source identity not yet known — deliver immediately as unverified
            // (matching Python), rather than deferring until the announce arrives.
            deliverWithUnknownSource(msg)
        }
    }

    // MARK: - Inbound delivery gate

    /// Central inbound-delivery gate, mirroring Python `LXMRouter.lxmf_delivery`.
    ///
    /// Runs, in order: ticket ingest (so future outbound messages to this source
    /// can skip proof-of-work), stamp validation + enforcement, ignore-list
    /// filtering, and duplicate suppression — then fires `onMessageReceived`.
    /// All previously-direct `onMessageReceived?(msg)` inbound calls funnel
    /// through here so the policy is applied uniformly regardless of whether the
    /// message arrived opportunistically, over a direct link, or after deferred
    /// signature validation.
    ///
    /// - Parameter noStampEnforcement: when `true`, an invalid stamp is allowed
    ///   through even if enforcement is enabled (mirrors Python's
    ///   `no_stamp_enforcement` — used for messages already validated upstream,
    ///   e.g. fetched from a propagation node).
    /// - Returns: `true` if delivered, `false` if dropped.
    @discardableResult
    func finalizeInboundDelivery(_ msg: LXMessage, noStampEnforcement: Bool = false) -> Bool {
        // 1. Ticket ingest. Only trust tickets on signature-validated messages.
        //    Mirrors Python: `if message.signature_validated and FIELD_TICKET in fields`.
        if msg.signatureValidated,
           let entry = msg.fields[Int(Field.ticket.rawValue)] as? [Any],
           entry.count > 1,
           let ticket = entry[1] as? Data,
           ticket.count == LXMessage.ticketLength {
            let expires: TimeInterval?
            switch entry[0] {
            case let d as Double:  expires = d
            case let i as Int:     expires = TimeInterval(i)
            case let i as Int64:   expires = TimeInterval(i)
            case let u as UInt64:  expires = TimeInterval(u)
            default:               expires = nil
            }
            if let expires, Date().timeIntervalSince1970 < expires {
                rememberTicket(destinationHash: msg.sourceHash, expiry: expires, ticket: ticket)
            }
        }

        // 2. Stamp validation + enforcement.
        //    Mirrors Python: `required_stamp_cost = delivery_destinations[dest].stamp_cost`.
        lock.lock()
        let requiredCost: Int? = inboundStampCosts[msg.destinationHash].flatMap { $0 }
        let enforcing = enforceStamps_
        lock.unlock()
        if let requiredCost {
            let tickets = getInboundTickets(destinationHash: msg.sourceHash)
            let valid = msg.validateStamp(targetCost: requiredCost, tickets: tickets)
            if !valid && !noStampEnforcement && enforcing {
                // Drop: invalid stamp under active enforcement.
                return false
            }
        }

        // 3. Ignore list.
        lock.lock()
        let ignored = ignoredList.contains(msg.sourceHash)
        lock.unlock()
        if ignored { return false }

        // 4. Duplicate suppression (mirrors Python's `has_message` /
        //    `locally_delivered_transient_ids`).
        if let tid = msg.hash {
            if hasMessage(transientID: tid) { return false }
            lock.lock(); locallyDeliveredTransientIDs[tid] = Date().timeIntervalSince1970; lock.unlock()
            saveLocallyDeliveredTransientIDs()   // persist across restarts
        }

        // 5. Deliver to the application.
        onMessageReceived?(msg)
        return true
    }

    // MARK: - Helpers

    private func removePending(_ msg: LXMessage) {
        lock.lock(); pendingOutbound.removeAll { $0 === msg }; lock.unlock()
    }

    /// Test helper: directly inject a message into the pending outbound queue.
    public func testInjectPendingOutbound(_ message: LXMessage) {
        lock.lock(); defer { lock.unlock() }
        if !pendingOutbound.contains(where: { $0 === message }) {
            pendingOutbound.append(message)
        }
    }

    /// Collect pending messages addressed to `destinationHash` and reset
    /// their delivery timer. Called by the announce handler when a peer
    /// announces its presence, triggering an immediate delivery attempt.
    internal func handleAnnounceForDestination(_ destinationHash: Data) {
        lock.lock()
        let matches = pendingOutbound.filter { $0.destinationHash == destinationHash }
        // Drain inbound messages waiting for this source's identity.
        let pendingSig = pendingSignatureValidation.filter { $0.message.sourceHash == destinationHash }
        pendingSignatureValidation.removeAll { $0.message.sourceHash == destinationHash }
        lock.unlock()

        for msg in matches where msg.method == .direct || msg.method == .opportunistic {
            msg.nextDeliveryAttempt = 0
        }
        if !matches.isEmpty { processOutbound() }

        // Validate inbound messages whose source identity has just been announced.
        // By the time `handleAnnounceForDestination` is called, the transport has
        // already stored the identity (knownIdentities[destinationHash] = identity
        // happens before announce handlers fire).
        if !pendingSig.isEmpty {
            let srcIdentity = transport.recall(identity: destinationHash)
            for (msg, _) in pendingSig {
                if let srcIdentity {
                    msg.validateSignature(knownIdentity: srcIdentity)
                } else {
                    msg.unverifiedReason = .sourceUnknown
                }
                finalizeInboundDelivery(msg)
            }
        }
    }

    // MARK: - Propagation node server

    /// Enable this router as a LXMF propagation node.
    ///
    /// Creates the message store directories, indexes existing messages,
    /// loads known peers, and registers the offer/get request handlers.
    ///
    /// Mirrors Python's `LXMRouter.enable_propagation()`.
    ///
    /// - Parameter path: Root storage directory. Subdirectories `lxmf/` and
    ///   `lxmf/messagestore/` are created as needed.
    /// - Throws: If directory creation fails.
    public func enablePropagation(storagePath path: String) throws {
        let rootPath = path + "/lxmf"
        let msgPath  = rootPath + "/messagestore"

        try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: msgPath,  withIntermediateDirectories: true)

        self.storagePath = rootPath
        self.messagePath = msgPath

        // Index existing messages in the store. (Setup-time; guarded for consistency —
        // LXMPeer.from below self-locks via the accessors, so it must NOT run under
        // the lock, hence the per-write locking rather than one wide critical section.)
        lock.lock(); propagationEntries.removeAll(); lock.unlock()
        let fm = FileManager.default
        if let filenames = try? fm.contentsOfDirectory(atPath: msgPath) {
            for filename in filenames {
                // Filename format: <hex_transient_id>_<timestamp>_<stamp_value>
                let parts = filename.split(separator: "_")
                guard parts.count >= 3 else { continue }
                let hexID      = String(parts[0])
                let tsStr      = String(parts[1])
                let stampStr   = String(parts[2])
                // transient_id = fullHash(lxmfData) = SHA-256 = 32 bytes = 64 hex chars
                guard hexID.count == 64,
                      let ts = TimeInterval(tsStr), ts > 0,
                      let sv = Int(stampStr) else { continue }
                guard let transientID = Data(hexString: hexID) else { continue }

                let filePath = msgPath + "/" + filename
                let attrs    = try? fm.attributesOfItem(atPath: filePath)
                let msgSize  = (attrs?[.size] as? Int) ?? 0

                // Read first 16 bytes = destination hash
                guard let fh = FileHandle(forReadingAtPath: filePath) else { continue }
                let destHash = fh.readData(ofLength: LXMessage.destinationLength)
                fh.closeFile()
                guard destHash.count == LXMessage.destinationLength else { continue }

                let entry = PropagationEntry(
                    destinationHash: destHash,
                    filePath:       filePath,
                    received:       ts,
                    msgSize:        msgSize,
                    handledPeers:   [],
                    unhandledPeers: [],
                    stampValue:     sv
                )
                lock.lock(); propagationEntries[transientID] = entry; lock.unlock()
            }
        }

        // Load serialised peer states.
        let peersPath = rootPath + "/peers"
        if fm.fileExists(atPath: peersPath),
           let peersData = fm.contents(atPath: peersPath),
           !peersData.isEmpty,
           case .array(let peerList) = (try? MsgPack.decode(peersData)) ?? .nil {
            for item in peerList {
                if case .bytes(let peerBytes) = item,
                   let peer = LXMPeer.from(bytes: Data(peerBytes), router: self) {
                    lock.lock(); peers[peer.destinationHash] = peer; lock.unlock()
                }
            }
        }

        // Load saved node statistics.
        let statsPath = rootPath + "/node_stats"
        if fm.fileExists(atPath: statsPath),
           let statsData = fm.contents(atPath: statsPath),
           case .map(let statsPairs) = (try? MsgPack.decode(statsData)) ?? .nil {
            var dict: [String: MsgPack.Value] = [:]
            for (k, v) in statsPairs { if case .string(let s) = k { dict[s] = v } }
            func statsInt(_ key: String) -> Int? {
                switch dict[key] {
                case .int(let n)?:  return Int(n)
                case .uint(let n)?: return Int(n)
                default:            return nil
                }
            }
            if let v = statsInt("client_propagation_messages_received") {
                clientPropagationMessagesReceived = v
            }
            if let v = statsInt("client_propagation_messages_served") {
                clientPropagationMessagesServed = v
            }
            if let v = statsInt("unpeered_propagation_incoming") {
                unpeeredPropagationIncoming = v
            }
            if let v = statsInt("unpeered_propagation_rx_bytes") {
                unpeeredPropagationRxBytes = v
            }
        }

        isPropagationNode        = true
        propagationNodeStartTime = Date().timeIntervalSince1970
        try? announcePropagationNode()  // mirrors Python enable_propagation() line 666

        // Register the offer and message_get request handlers on the propagation destination.
        // Mirrors Python's enable_propagation() lines 650-651.
        propagationDestination?.registerNativeRequestHandler(
            path: LXMPeer.offerRequestPath,
            allow: .all
        ) { [weak self] _, requestData, _, link, _ -> MsgPack.Value? in
            guard let self else { return nil }
            return self.handleOfferRequest(data: requestData, on: link)
        }

        propagationDestination?.registerNativeRequestHandler(
            path: LXMPeer.messageGetPath,
            allow: .all
        ) { [weak self] _, requestData, _, link, _ -> MsgPack.Value? in
            guard let self else { return nil }
            // Derive the client's delivery destination hash from their identity.
            let remoteDeliveryHash: Data? = link.remoteIdentity.flatMap { id in
                try? Destination(identity: id, direction: .in, kind: .single,
                                 appName: APP_NAME, aspects: ["delivery"]).hash
            }
            return self.handleMessageGetRequest(data: requestData,
                                                remoteDeliveryHash: remoteDeliveryHash)
        }

        // Set up the link callback to accept resource uploads from clients/peers.
        // Mirrors Python's propagation_link_established() callback.
        propagationDestination?.onLinkEstablished = { [weak self] link in
            guard let self else { return }
            link.resourceStrategy = .acceptApp
            link.onResourceAdvertised = { [weak self] resource, _ -> Bool in
                guard let self else { return false }
                if let limit = self.propagationPerSyncLimit {
                    return Int(resource.dataSize) <= limit * 1000
                }
                return true
            }
            link.onResourceConcluded = { [weak self] data, _, concludingLink in
                self?.handleInboundPropagationResource(data, on: concludingLink)
            }
            // Evict this link's PN-link bookkeeping when it closes (growth fix:
            // validatedPeerLinks was inserted on every offer request but never
            // removed). Chain any pre-existing onClosed so nothing is clobbered.
            let priorOnClosed = link.onClosed
            link.onClosed = { [weak self] l in
                priorOnClosed?(l)
                guard let self else { return }
                self.lock.lock()
                self.validatedPeerLinks.removeValue(forKey: ObjectIdentifier(l))
                self.activePropagationLinks.removeValue(forKey: ObjectIdentifier(l))
                self.lock.unlock()
            }
        }
    }

    /// Disable propagation node mode and save state.
    ///
    /// Mirrors Python's `LXMRouter.disable_propagation()`.
    public func disablePropagation() {
        guard isPropagationNode else { return }
        savePeers()
        saveNodeStats()
        propagationDestination?.deregisterRequestHandler(path: LXMPeer.offerRequestPath)
        propagationDestination?.deregisterRequestHandler(path: LXMPeer.messageGetPath)
        propagationDestination?.onLinkEstablished = nil
        isPropagationNode    = false
        propagationNodeStartTime = nil
        try? announcePropagationNode()  // mirrors Python disable_propagation() line 675 (re-announces with node_state=false)
    }

    /// Process a resource uploaded to the propagation destination (from a client or peer).
    ///
    /// Wire format: `msgpack([timestamp, [lxmf_data_with_stamp, ...]])`
    /// where each element = `destHash + encrypt(payload) + 32-byte-stamp`.
    ///
    /// Mirrors Python's `propagation_resource_concluded()`.
    ///
    /// `link` is the link the resource concluded on, and is what identifies the sender. Python
    /// derives the remote's propagation destination from `resource.link.get_remote_identity()`
    /// (`LXMRouter.py:2348-2352`) and every decision that depends on *who* uploaded — autopeering
    /// (`:2366-2375`) and stamp throttling (`:2449-2454`) — reads it from there. Pass the link
    /// whenever one exists.
    public func handleInboundPropagationResource(_ data: Data, on link: Link?) {
        guard case .array(let outer) = (try? MsgPack.decode(data)) ?? .nil,
              outer.count >= 2,
              case .array(let messages) = outer[1] else { return }

        let transientList: [Data] = messages.compactMap {
            if case .bytes(let b) = $0 { return Data(b) }
            return nil
        }

        // Derived once, here, rather than at each site that needs it: autopeering, stamp throttling
        // and the single-packet upload path (`bugs/021`) all ask the same question of the same
        // link, and N independent derivations is how the `bugs/013` sub-defects came back
        // (design D1).
        let sender = link.flatMap { remotePropagationHash(of: $0) }

        let minCost = max(0, propagationStampCost - propagationStampCostFlexibility)
        let validated = LXStamper.validatePNStamps(transientList: transientList, targetCost: minCost)
        for entry in validated {
            lock.lock(); clientPropagationMessagesReceived += 1; lock.unlock()
            _ = ingestPropagatedLXM(lxmfData: entry.lxmfData,
                                    stampValue: entry.stampValue,
                                    stamp:      entry.stamp)
        }

        // A transfer carrying messages whose stamps do not validate costs this node full
        // validation over the whole set, and nothing stops the remote from retrying it at whatever
        // rate it likes. Python throttles the sender and tears the link down
        // (`LXMRouter.py:2447-2454`); the port could decode `ERROR_THROTTLED` as a client and had
        // no path that emitted it.
        let invalidCount = transientList.count - validated.count
        if invalidCount > 0, let sender {
            lock.lock()
            throttledPeers[sender] = Date().timeIntervalSince1970 + LXMRouter.pnStampThrottle
            lock.unlock()
            try? link?.teardown()
        }

        if let sender { considerAutopeering(with: sender) }
    }

    /// Ingest a propagation payload with no sender attached.
    ///
    /// **Does not peer and does not throttle** — both need to know who uploaded, and this entry
    /// point does not. It exists for callers that genuinely have no link (tests driving the store,
    /// and re-ingest from disk); anything reached from a propagation link must use the variant
    /// above.
    public func handleInboundPropagationResource(_ data: Data) {
        handleInboundPropagationResource(data, on: nil)
    }

    /// The remote's propagation destination hash for a link it identified on, or nil if it has
    /// not identified. Python: `RNS.Destination(remote_identity, OUT, SINGLE, APP_NAME,
    /// "propagation").hash` (`LXMRouter.py:2350-2351`).
    func remotePropagationHash(of link: Link) -> Data? {
        guard let remoteIdentity = link.remoteIdentity else { return nil }
        return try? Destination(identity: remoteIdentity, direction: .out, kind: .single,
                                appName: APP_NAME, aspects: ["propagation"]).hash
    }

    // MARK: - Message store

    /// Total bytes currently used by the message store.
    /// Returns nil when not acting as a propagation node.
    /// Python: `LXMRouter.message_storage_size()`.
    public func messageStorageSize() -> Int? {
        guard isPropagationNode else { return nil }
        lock.lock(); defer { lock.unlock() }
        return propagationEntries.values.reduce(0) { $0 + $1.msgSize }
    }

    /// Set the maximum total bytes for the message store.
    /// Mirrors Python `LXMRouter.set_message_storage_limit()`.
    public func setMessageStorageLimit(kilobytes: Int? = nil,
                                       megabytes: Int? = nil,
                                       gigabytes: Int? = nil) {
        var bytes = 0
        if let kb = kilobytes { bytes += kb * 1000 }
        if let mb = megabytes { bytes += mb * 1_000_000 }
        if let gb = gigabytes { bytes += gb * 1_000_000_000 }
        messageStorageLimit = bytes == 0 ? nil : bytes
    }

    /// Store an incoming LXMF message in the message store.
    ///
    /// The file is named `<hex_transient_id>_<timestamp>_<stamp_value>`.
    ///
    /// - Parameters:
    ///   - lxmfData: Raw LXMF bytes (without the trailing stamp).
    ///   - transientID: SHA-256 hash of `lxmfData` (the message's unique ID).
    ///   - stampValue: Proof-of-work value of the stamp.
    ///   - stamp: The 32-byte stamp appended to lxmfData on disk.
    /// - Returns: The created PropagationEntry, or nil if storage failed.
    @discardableResult
    public func addToMessageStore(lxmfData: Data, transientID: Data,
                                  stampValue: Int, stamp: Data) -> PropagationEntry? {
        guard let mp = messagePath else { return nil }
        guard lxmfData.count >= LXMessage.destinationLength else { return nil }

        // Existing entry? Skip. (dedup check under the lock)
        //
        // The tombstone cache is checked alongside it: once a message has been
        // delivered and pruned from propagationEntries, only
        // locallyProcessedTransientIDs remembers it, and without that check the
        // very next peer to offer it would have it re-ingested from scratch.
        // Mirrors Python's `not transient_id in self.propagation_entries and
        // not transient_id in self.locally_processed_transient_ids`.
        lock.lock()
        if let existing = propagationEntries[transientID] { lock.unlock(); return existing }
        if locallyProcessedTransientIDs[transientID] != nil { lock.unlock(); return nil }
        lock.unlock()

        let received  = Date().timeIntervalSince1970
        let hexID     = transientID.map { String(format: "%02x", $0) }.joined()
        let filename  = "\(hexID)_\(received)_\(stampValue)"
        let filePath  = mp + "/" + filename

        // Write lxmfData + stamp to disk — OUTSIDE the lock (blocking I/O).
        var fileBytes = lxmfData
        fileBytes.append(stamp)
        guard (try? fileBytes.write(to: URL(fileURLWithPath: filePath))) != nil else { return nil }

        let destHash = Data(lxmfData.prefix(LXMessage.destinationLength))
        // Re-check dedup + construct the entry under the lock (unhandledPeers reflects
        // the peer set at insert time; a concurrent add of the same transientID that
        // won while we wrote the file is honoured — we return its entry).
        lock.lock()
        if let existing = propagationEntries[transientID] {
            lock.unlock()
            // A concurrent add won the race; drop the file we just wrote so it isn't orphaned.
            try? FileManager.default.removeItem(atPath: filePath)
            return existing
        }
        let entry = PropagationEntry(
            destinationHash: destHash,
            filePath:       filePath,
            received:       received,
            msgSize:        fileBytes.count,
            handledPeers:   [],
            unhandledPeers: Array(peers.keys),  // all peers need this message
            stampValue:     stampValue
        )
        propagationEntries[transientID] = entry
        lock.unlock()
        return entry
    }

    /// Remove a message from the store (delete file + entry).
    /// Python: `os.unlink(filepath)` + `propagation_entries.pop(transient_id)`.
    public func removeFromMessageStore(transientID: Data) {
        // Remove the entry under the lock; snapshot its file path and unlink OUTSIDE.
        lock.lock()
        guard let entry = propagationEntries.removeValue(forKey: transientID) else { lock.unlock(); return }
        // Remember that we handled it, so it is not re-ingested after the entry
        // is gone. Expired on the same schedule as the delivered cache.
        locallyProcessedTransientIDs[transientID] = Date().timeIntervalSince1970
        lock.unlock()
        try? FileManager.default.removeItem(atPath: entry.filePath)
    }

    /// Clean the message store, removing the oldest messages when over the storage limit.
    /// Mirrors Python's `LXMRouter.clean_message_store()`.
    public func cleanMessageStore() {
        guard isPropagationNode else { return }
        guard let limit = messageStorageLimit else { return }

        // Compute size + snapshot the sort order under the lock; delete OUTSIDE
        // (removeFromMessageStore self-locks and unlinks the file outside the lock).
        lock.lock()
        var currentSize = propagationEntries.values.reduce(0) { $0 + $1.msgSize }
        guard currentSize > limit else { lock.unlock(); return }
        let sorted = propagationEntries.sorted { $0.value.received < $1.value.received }
        lock.unlock()

        for (tid, entry) in sorted {
            guard currentSize > limit else { break }
            currentSize -= entry.msgSize
            removeFromMessageStore(transientID: tid)
        }
    }

    // MARK: - Synchronized propagationEntries accessors (used by LXMPeer)
    //
    // LXMPeer must NOT touch `propagationEntries` directly — the in-place value
    // mutations (handledPeers/unhandledPeers) and reads run on link-callback / sync
    // threads concurrently with the router's own PN handlers. These accessors serialize
    // every such access under the router `lock`. Each is a leaf operation (no callout),
    // so it is safe to hold the lock for its duration.

    func peerEntryExists(_ transientID: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }; return propagationEntries[transientID] != nil
    }
    func peerEntry(_ transientID: Data) -> PropagationEntry? {
        lock.lock(); defer { lock.unlock() }; return propagationEntries[transientID]
    }
    func peerHandledTransientIDs(for destinationHash: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return propagationEntries.compactMap { $0.value.handledPeers.contains(destinationHash) ? $0.key : nil }
    }
    func peerUnhandledTransientIDs(for destinationHash: Data) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return propagationEntries.compactMap { $0.value.unhandledPeers.contains(destinationHash) ? $0.key : nil }
    }
    /// Add `destinationHash` to the entry's handledPeers. Returns true iff the entry
    /// existed and the peer was newly added (so the caller can invalidate its count cache).
    @discardableResult
    func peerAddHandled(_ transientID: Data, destinationHash: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard propagationEntries[transientID] != nil else { return false }
        if !propagationEntries[transientID]!.handledPeers.contains(destinationHash) {
            propagationEntries[transientID]!.handledPeers.append(destinationHash)
            return true
        }
        return false
    }
    @discardableResult
    func peerAddUnhandled(_ transientID: Data, destinationHash: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard propagationEntries[transientID] != nil else { return false }
        if !propagationEntries[transientID]!.unhandledPeers.contains(destinationHash) {
            propagationEntries[transientID]!.unhandledPeers.append(destinationHash)
            return true
        }
        return false
    }
    /// Remove `destinationHash` from the entry's handledPeers. Returns true iff the entry existed.
    @discardableResult
    func peerRemoveHandled(_ transientID: Data, destinationHash: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard propagationEntries[transientID] != nil else { return false }
        propagationEntries[transientID]!.handledPeers.removeAll { $0 == destinationHash }
        return true
    }
    @discardableResult
    func peerRemoveUnhandled(_ transientID: Data, destinationHash: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard propagationEntries[transientID] != nil else { return false }
        propagationEntries[transientID]!.unhandledPeers.removeAll { $0 == destinationHash }
        return true
    }

    // MARK: - Peer management

    /// Peer with a propagation node, or update an existing peering.
    ///
    /// Mirrors Python's `LXMRouter.peer()` (`LXMRouter.py:2004-2047`). This is the **only** way a
    /// peer is created: the reference applies its limits here rather than at the call sites that
    /// peer, so no caller can peer some other way and skip them (design D2).
    ///
    /// An existing peer is updated only when `timestamp` is newer than its current peering
    /// timebase (`:2013`), so a replayed or reordered announce cannot reset a peer's negotiated
    /// state.
    public func peer(destinationHash: Data,
                     timestamp: TimeInterval,
                     transferLimit: Double?,
                     syncLimit: Double?,
                     stampCost: Int,
                     stampCostFlexibility: Int,
                     peeringCost: Int,
                     metadata: [String: String]?) {
        lock.lock()
        let existing   = peers[destinationHash]
        let tableIsFull = peers.count >= maxPeers
        lock.unlock()

        // The ceiling is about what the remote *demands*, so it is checked before anything else
        // and applies to an existing peering too: a peer that raises its cost past what this node
        // will pay has the peering broken, not merely a new one declined (`LXMRouter.py:2005-2010`).
        guard peeringCost <= maxPeeringCost else {
            if existing != nil { unpeer(destinationHash: destinationHash, timestamp: timestamp) }
            return
        }

        if let existing {
            guard timestamp > existing.peeringTimebase else { return }
            apply(announcedTimestamp: timestamp, transferLimit: transferLimit,
                  syncLimit: syncLimit, stampCost: stampCost,
                  stampCostFlexibility: stampCostFlexibility, peeringCost: peeringCost,
                  metadata: metadata, to: existing)
            // Python also clears the backoff on re-peering (`:2017-2018`), so a peer that comes
            // back after a run of failures is retried at once rather than after its accumulated
            // wait.
            existing.syncBackoff     = 0
            existing.nextSyncAttempt = 0
            return
        }

        // The bound applies to admitting a *new* peer only — an existing peer's negotiated limits
        // are still updated above, or a full node stops tracking what its peers will accept.
        guard !tableIsFull else { return }

        let peer = addPeer(destinationHash: destinationHash)
        apply(announcedTimestamp: timestamp, transferLimit: transferLimit,
              syncLimit: syncLimit, stampCost: stampCost,
              stampCostFlexibility: stampCostFlexibility, peeringCost: peeringCost,
              metadata: metadata, to: peer)
    }

    /// The field assignments Python makes identically in both branches of `peer()`
    /// (`:2014-2029` and `:2035-2046`) — shared so the two cannot drift apart.
    private func apply(announcedTimestamp: TimeInterval,
                       transferLimit: Double?,
                       syncLimit: Double?,
                       stampCost: Int,
                       stampCostFlexibility: Int,
                       peeringCost: Int,
                       metadata: [String: String]?,
                       to peer: LXMPeer) {
        peer.alive                          = true
        peer.metadata                       = metadata
        peer.peeringTimebase                = announcedTimestamp
        peer.lastHeard                      = Date().timeIntervalSince1970
        peer.propagationStampCost           = stampCost
        peer.propagationStampCostFlexibility = stampCostFlexibility
        peer.peeringCost                    = peeringCost
        peer.propagationTransferLimit       = transferLimit
        // Python: an unset sync limit means "same as the transfer limit" (`:2028-2029`).
        peer.propagationSyncLimit           = syncLimit ?? transferLimit
    }

    /// Peer with the sender of a sync, if the reference's conditions are met.
    ///
    /// Python does this on concluding an incoming propagation transfer (`LXMRouter.py:2357-2375`):
    /// a remote that is not already a peer, whose recalled announce data says it is an active
    /// propagation node, is peered with when autopeering is on and it is within
    /// `autopeer_maxdepth` hops.
    func considerAutopeering(with propagationHash: Data) {
        guard autopeer else { return }

        lock.lock()
        let alreadyPeered = peers[propagationHash] != nil
        lock.unlock()
        guard !alreadyPeered else { return }

        guard let announce = PropagationNodeAnnounce(
            appData: transport.recallAppData(forDestination: propagationHash)),
              announce.isPropagationNode
        else { return }

        // Python's `Transport.hops_to` answers `PATHFINDER_M` (128) for a destination it has no
        // path to, so an unknown hop count fails the depth test rather than passing it.
        guard let hops = transport.hopsTo(propagationHash),
              Int(hops) <= autopeerMaxdepth
        else { return }

        peer(destinationHash: propagationHash,
             timestamp: announce.timebase,
             transferLimit: announce.transferLimit,
             syncLimit: announce.syncLimit,
             stampCost: announce.stampCost,
             stampCostFlexibility: announce.stampCostFlexibility,
             peeringCost: announce.peeringCost,
             metadata: announce.metadata)
    }

    /// Insert a peer into the table unconditionally.
    ///
    /// The internal half of `peer(destinationHash:...)`, which is where the reference's peering
    /// conditions live. Not public: a caller that reached this directly would bypass them.
    @discardableResult
    func addPeer(destinationHash: Data,
                 syncStrategy: LXMSyncStrategy = LXMPeer.defaultSyncStrategy) -> LXMPeer {
        lock.lock()
        if let existing = peers[destinationHash] { lock.unlock(); return existing }
        let peer = LXMPeer(router: self, destinationHash: destinationHash,
                           syncStrategy: syncStrategy)
        peers[destinationHash] = peer
        // Snapshot existing message IDs, then seed the new peer OUTSIDE the lock
        // (addUnhandledMessage self-locks; seeding is idempotent — peerAddUnhandled
        // dedups — so a concurrent addToMessageStore that already included the new
        // peer causes no double-add).
        let allTids = Array(propagationEntries.keys)
        lock.unlock()
        for tid in allTids { peer.addUnhandledMessage(tid) }
        return peer
    }

    // MARK: - Periodic jobs

    /// One entry of the periodic job schedule.
    ///
    /// The schedule is data rather than a chain of `if processingCount % … == 0` blocks so that
    /// "which routines run, and how often" is a value a test can compare against the reference
    /// (`LXMRouter.py:880-911`) — a missing routine is then a failing assertion rather than an
    /// absence nobody can see, which is how `swift_devel/bugs/019` survived.
    public struct Job {
        /// The routine's name, matching the Swift method it dispatches.
        public let name: String
        /// How many ticks apart it runs. Python's `JOB_*_INTERVAL`.
        public let interval: Int
        /// Whether the reference runs it only on a propagation node.
        public let propagationNodeOnly: Bool
        /// Non-nil when the port schedules the routine but has not implemented it yet, saying why.
        ///
        /// Recorded rather than left out of the schedule: an omitted routine is indistinguishable
        /// from one nobody noticed.
        public let pendingReason: String?
        let run: (LXMRouter) -> Void

        init(_ name: String, every interval: Int, propagationNodeOnly: Bool = false,
             pending pendingReason: String? = nil, run: @escaping (LXMRouter) -> Void = { _ in }) {
            self.name = name
            self.interval = interval
            self.propagationNodeOnly = propagationNodeOnly
            self.pendingReason = pendingReason
            self.run = run
        }
    }

    /// The reference's `jobs()` as a schedule. Mirrors `LXMRouter.py:880-911`.
    public static let jobSchedule: [Job] = []

    /// Run the routines due on this tick, and return their names.
    ///
    /// The return value is what makes dispatch observable without instrumenting production: a test
    /// can drive the schedule and see exactly which routines ran on which tick. `LXMRouter` is
    /// `public final`, so there is no subclass to spy with.
    @discardableResult
    public func jobs() -> [String] {
        []
    }

    /// Drop throttle records that have expired.
    /// Mirrors Python's `LXMRouter.clean_throttled_peers()` (`LXMRouter.py:1136-1142`).
    public func cleanThrottledPeers(now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock(); defer { lock.unlock() }
        for (destinationHash, deadline) in throttledPeers where now > deadline {
            throttledPeers.removeValue(forKey: destinationHash)
        }
    }

    /// Drop low-acceptance-rate peers to recover headroom under `maxPeers`.
    ///
    /// Mirrors Python's `LXMRouter.rotate_peers()` (`LXMRouter.py:2060-2130`), kept as one routine
    /// in the reference's order because its steps depend on each other: the postponement depends on
    /// the untested count, the pool basis on the fully-synced set, and the drop pool on
    /// `prioritiseRotatingUnreachablePeers` (design D4).
    public func rotatePeers() {
        lock.lock()
        let all = Array(peers.values)
        let staticHashes = staticPeers
        let bound = maxPeers
        lock.unlock()

        // Headroom, and whether the table is far enough over it to be worth rotating. The second
        // condition keeps a tiny table from rotating itself down to nothing (`:2064`).
        let headroom = max(1, Int((Double(bound) * Double(LXMRouter.rotationHeadroomPct) / 100.0)
                                  .rounded(.down)))
        let requiredDrops = all.count - (bound - headroom)
        guard requiredDrops > 0, all.count - requiredDrops > 1 else { return }

        // A peer that has never been synced with has no record to be judged on. While enough of
        // them are outstanding, the whole pass is postponed rather than judging them (`:2067-2075`)
        // — otherwise rotation drops whichever peer was added most recently.
        let untested = all.filter { $0.lastSyncAttempt == 0 }
        guard untested.count < headroom else { return }

        // Prefer peers that have taken everything offered as the basis, when any have: a peer with
        // messages still outstanding has an acceptance rate that has not finished being measured
        // (`:2075-2084`).
        let fullySynced = all.filter { $0.unhandledMessageCount == 0 }
        let basis = fullySynced.isEmpty ? all : fullySynced

        var waiting:      [LXMPeer] = []
        var unresponsive: [LXMPeer] = []
        for peer in basis where !staticHashes.contains(peer.destinationHash) && peer.state == .idle {
            if peer.alive {
                // Offered nothing, so there is no acceptance rate to judge — not a candidate,
                // rather than a candidate scoring zero (`:2095-2098`).
                if peer.offered != 0 { waiting.append(peer) }
            } else {
                unresponsive.append(peer)
            }
        }

        var dropPool: [LXMPeer] = []
        if !unresponsive.isEmpty {
            dropPool = unresponsive
            if !prioritiseRotatingUnreachablePeers { dropPool.append(contentsOf: waiting) }
        } else {
            dropPool = waiting
        }
        guard !dropPool.isEmpty else { return }

        let dropCount = min(requiredDrops, dropPool.count)
        let lowestAcceptance = dropPool
            .sorted { $0.acceptanceRate < $1.acceptanceRate }
            .prefix(dropCount)

        for peer in lowestAcceptance where peer.acceptanceRate < LXMRouter.rotationAcceptanceRateMax {
            unpeer(destinationHash: peer.destinationHash)
        }
    }

    /// Break peering with a node.
    ///
    /// Mirrors Python's `LXMRouter.unpeer()` (`LXMRouter.py:2049-2057`) — the removal path used by
    /// rotation (`:2122`), by the peering-cost ceiling (`:2008`) and by the remote control verb
    /// `peer_unpeer_request` (`:864`).
    ///
    /// `timestamp` defaults to now, which is what makes a locally-decided unpeer (rotation, the
    /// ceiling) always take effect. An unpeer carrying a timebase *older* than the peer's is
    /// ignored: announces reorder in a mesh, and without the guard a delayed unpeer removes a peer
    /// that has since re-peered.
    public func unpeer(destinationHash: Data, timestamp: TimeInterval? = nil) {
        let stamp = timestamp ?? Date().timeIntervalSince1970

        lock.lock()
        let peeringTimebase = peers[destinationHash]?.peeringTimebase
        lock.unlock()

        guard let peeringTimebase else { return }
        guard stamp >= peeringTimebase else { return }
        removePeer(destinationHash: destinationHash)
    }

    /// Remove a peer from the peering table.
    public func removePeer(destinationHash: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let peer = peers.removeValue(forKey: destinationHash) else { return }
        // Clean up that peer's references from all propagation entries (in-place value
        // mutation, no callout — safe to hold the lock). Snapshot the keys first to
        // avoid mutating-during-iteration of the dictionary.
        for tid in Array(propagationEntries.keys) {
            propagationEntries[tid]?.handledPeers.removeAll { $0 == peer.destinationHash }
            propagationEntries[tid]?.unhandledPeers.removeAll { $0 == peer.destinationHash }
        }
    }

    // MARK: - Distribution queue

    /// Notify all peers that a new message has arrived and queue it for distribution.
    /// Python: `LXMRouter.peer_distribution_queue.append(transient_id)` + per-peer queue.
    public func enqueueForPeerDistribution(transientID: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !peerDistributionQueue.contains(transientID) else { return }
        peerDistributionQueue.append(transientID)
    }

    /// Flush the peer distribution queue — mark new messages as unhandled for all peers.
    /// Python: `LXMRouter.flush_peer_distribution_queue()`.
    public func flushPeerDistributionQueue() {
        guard isPropagationNode else { return }
        // Drain the whole queue + snapshot the peer set under the lock; do the per-peer
        // queueing/processing (which self-locks via the propagationEntries accessors)
        // OUTSIDE the lock. Order preserved (batch is in queue order).
        lock.lock()
        guard !peerDistributionQueue.isEmpty else { lock.unlock(); return }
        let batch = peerDistributionQueue
        peerDistributionQueue.removeAll()
        let peerList = Array(peers.values)
        lock.unlock()

        for tid in batch {
            for peer in peerList { peer.queueUnhandledMessage(tid) }
        }
        for peer in peerList { peer.processQueues() }
    }

    /// Attempt to sync with all peers.
    /// Python: `LXMRouter.sync_peers()`.
    public func syncPeers() {
        var generator = SystemRandomNumberGenerator()
        syncPeers(using: &generator)
    }

    /// `syncPeers()` with the selection source supplied, so a test can assert which peers the pool
    /// can reach without pinning production to a fixed choice (design D5).
    public func syncPeers<G: RandomNumberGenerator>(using generator: inout G) {
        guard isPropagationNode else { return }
        lock.lock()
        let all = Array(peers.values)
        let staticHashes = staticPeers
        lock.unlock()

        let now = Date().timeIntervalSince1970
        var culled:       [Data]    = []
        var waiting:      [LXMPeer] = []
        var unresponsive: [LXMPeer] = []

        for peer in all {
            // A peer not heard from for MAX_UNREACHABLE has gone away; without this it is
            // attempted on every pass for the life of the process. A static peer is the operator's
            // declared upstream and is exempt — a node behind a constrained link may legitimately
            // be silent this long (`LXMRouter.py:2138-2140`).
            if now > peer.lastHeard + LXMPeer.maxUnreachable {
                if !staticHashes.contains(peer.destinationHash) {
                    culled.append(peer.destinationHash)
                }
                continue
            }

            guard peer.state == .idle, peer.unhandledMessageCount > 0 else { continue }
            if peer.alive {
                waiting.append(peer)
            } else if now > peer.nextSyncAttempt {
                // Otherwise it is in sync backoff, and dialling it every pass is what backoff
                // exists to prevent (`:2145`).
                unresponsive.append(peer)
            }
        }

        // The pool: the fastest peers by measured throughput, widened with up to as many again
        // whose speed is not yet known (`:2148-2166`). The mix is deliberate — it lets a node
        // converge on its good peers without starving peers it has never tried.
        var pool: [LXMPeer] = []
        if !waiting.isEmpty {
            let fastest = waiting
                .sorted { $0.syncTransferRate > $1.syncTransferRate }
                .prefix(min(LXMRouter.fastestNRandomPool, waiting.count))
            pool.append(contentsOf: fastest)

            // A peer whose rate is still 0 can land in `fastest` as well — when every waiting peer
            // is unmeasured, they all do — and so appears in the pool twice, weighting the draw
            // toward it. The reference does exactly this (`:2151-2166` extends the same list), and
            // it is left alone: de-duplicating would change the selection distribution away from
            // the reference's for no stated reason.
            let unknownSpeed = waiting.filter { $0.syncTransferRate == 0 }
            pool.append(contentsOf: unknownSpeed.prefix(min(unknownSpeed.count, fastest.count)))
        } else {
            // Unresponsive peers are the pool only when nobody reachable is waiting (`:2168-2170`).
            pool = unresponsive
        }

        // One peer per pass, not all of them (`:2172-2176`).
        if let selected = pool.randomElement(using: &generator) { selected.sync() }

        for destinationHash in culled { removePeer(destinationHash: destinationHash) }
    }

    // MARK: - Offer / get request handlers

    /// Handle an incoming sync offer request from a remote propagation peer.
    ///
    /// Validates the peering key and returns a list of wanted transient IDs.
    ///
    /// Mirrors Python's `LXMRouter.offer_request()`.
    ///
    /// - Parameters:
    ///   - data: Decoded msgpack: [peeringKey: Data, transientIDs: [Data]]
    ///   - link: the link the request arrived on. Two different hashes are derived from it and
    ///     they are not interchangeable: the peering key is computed over the remote's *identity*
    ///     hash (`LXMRouter.py:2298`), while the throttle is keyed by its *propagation destination*
    ///     hash (`:2269-2270`). Taking a pre-narrowed identity hash here, as this method used to,
    ///     makes the second one underivable (design D1).
    /// - Returns: Response value:
    ///   - `LXMPeerError.noIdentity` if not identified
    ///   - `LXMPeerError.throttled` if the remote is inside a throttle window
    ///   - `false` (MsgPack.Value.bool) if we already have all offered messages
    ///   - `true`  if we want all offered messages
    ///   - `[Data]` list of wanted transient IDs
    public func handleOfferRequest(data: MsgPack.Value, on link: Link) -> MsgPack.Value {
        handleOfferRequest(data: data,
                           remoteIdentityHash: link.remoteIdentity?.hash,
                           propagationHash: remotePropagationHash(of: link),
                           linkID: ObjectIdentifier(link))
    }

    /// The offer handler with its two hashes supplied separately.
    ///
    /// Internal, and the only production caller is the entry point above — a `propagationHash` of
    /// `nil` **cannot be throttled**, so nothing reachable from a link may use this directly. It
    /// exists for tests of the wanted-IDs logic, which have no link and no interest in one; giving
    /// the concurrency test a real link would put link machinery inside a race test.
    func handleOfferRequest(data: MsgPack.Value,
                            remoteIdentityHash: Data?,
                            propagationHash: Data?,
                            linkID: ObjectIdentifier) -> MsgPack.Value {
        guard isPropagationNode else { return .int(Int64(LXMPeerError.noAccess.rawValue)) }
        guard let remoteHash = remoteIdentityHash else {
            return .int(Int64(LXMPeerError.noIdentity.rawValue))
        }

        // Refuse while the remote is throttled, and drop the record once it has elapsed. The
        // scheduled sweep (`cleanThrottledPeers`) is not a substitute: this branch only fires for a
        // remote that comes back (`LXMRouter.py:2285-2290`).
        if let propagationHash {
            let now = Date().timeIntervalSince1970
            lock.lock()
            let deadline = throttledPeers[propagationHash]
            if let deadline, deadline <= now { throttledPeers.removeValue(forKey: propagationHash) }
            lock.unlock()
            if let deadline, deadline > now {
                return .int(Int64(LXMPeerError.throttled.rawValue))
            }
        }

        guard case .array(let dataArr) = data, dataArr.count >= 2 else {
            return .int(Int64(LXMPeerError.invalidData.rawValue))
        }
        guard case .bytes(let keyBytes) = dataArr[0],
              case .array(let idsArr)   = dataArr[1] else {
            return .int(Int64(LXMPeerError.invalidData.rawValue))
        }

        let peeringKeyData  = Data(keyBytes)
        let offeredIDs: [Data] = idsArr.compactMap {
            if case .bytes(let b) = $0 { return Data(b) } else { return nil }
        }

        // Validate peering key if we have a peering cost.
        if peeringCost > 0 {
            let peeringID = (identity?.hash ?? Data()) + remoteHash
            guard LXStamper.validatePeeringKey(
                peeringID: peeringID, peeringKey: peeringKeyData, targetCost: peeringCost
            ) else {
                return .int(Int64(LXMPeerError.invalidKey.rawValue))
            }
        }

        // Record the validated link + build the wanted-IDs list under the lock
        // (messages the peer offered that we don't have yet).
        lock.lock()
        validatedPeerLinks[linkID] = true
        let wantedIDs = offeredIDs.filter { propagationEntries[$0] == nil }
        lock.unlock()

        if wantedIDs.isEmpty          { return .bool(false) }
        if wantedIDs.count == offeredIDs.count { return .bool(true) }
        return .array(wantedIDs.map { .bytes($0) })
    }

    /// Handle an incoming message download request from a client.
    ///
    /// Returns the list of available transient IDs for the requesting destination,
    /// or the requested message bytes.
    ///
    /// Mirrors Python's `LXMRouter.message_get_request()`.
    ///
    /// - Parameters:
    ///   - data: msgpack: [want: [Data]?, have: [Data]?, limit_kb: Double?]
    ///   - remoteDeliveryHash: 16-byte delivery destination hash of the client.
    /// - Returns: Response msgpack value.
    public func handleMessageGetRequest(data: MsgPack.Value,
                                        remoteDeliveryHash: Data?) -> MsgPack.Value {
        guard let destHash = remoteDeliveryHash else {
            return .int(Int64(LXMPeerError.noIdentity.rawValue))
        }
        guard isPropagationNode else { return .int(Int64(LXMPeerError.noAccess.rawValue)) }

        guard case .array(let dataArr) = data, dataArr.count >= 2 else {
            return .int(Int64(LXMPeerError.invalidData.rawValue))
        }

        let wantList: [Data]? = {
            if case .array(let arr) = dataArr[0] {
                return arr.compactMap { if case .bytes(let b) = $0 { return Data(b) } else { return nil } }
            }
            return nil
        }()
        let haveList: [Data]? = {
            if case .array(let arr) = dataArr[1] {
                return arr.compactMap { if case .bytes(let b) = $0 { return Data(b) } else { return nil } }
            }
            return nil
        }()
        let clientLimitKB: Double? = {
            if dataArr.count >= 3, case .double(let v) = dataArr[2] { return v }
            return nil
        }()

        // No want/have = client requesting the list of available messages.
        if wantList == nil && haveList == nil {
            lock.lock()
            let available = propagationEntries.compactMap { (tid, entry) -> (Data, Int)? in
                entry.destinationHash == destHash ? (tid, entry.msgSize) : nil
            }
            lock.unlock()
            let sorted = available.sorted { $0.1 < $1.1 }
            return .array(sorted.map { .bytes($0.0) })
        }

        // Process "have" list — client already has these, delete from store.
        // Snapshot the tids to purge under the lock; removeFromMessageStore self-locks
        // + unlinks the file OUTSIDE the lock.
        if let have = haveList {
            lock.lock()
            let toPurge = have.filter { propagationEntries[$0]?.destinationHash == destHash }
            lock.unlock()
            for tid in toPurge { removeFromMessageStore(transientID: tid) }
        }

        // Process "want" list — snapshot the file paths under the lock, read files OUTSIDE.
        var responseMessages: [MsgPack.Value] = []
        let perMsgOverhead = 16
        var cumulative     = 24

        if let want = wantList {
            lock.lock()
            let wantedPaths: [String] = want.compactMap { tid in
                guard let entry = propagationEntries[tid], entry.destinationHash == destHash else { return nil }
                return entry.filePath
            }
            lock.unlock()
            for filePath in wantedPaths {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { continue }

                let msgSize  = data.count
                let nextSize = cumulative + msgSize + perMsgOverhead
                if let limit = clientLimitKB, Double(nextSize) > limit * 1000 { continue }

                // Return lxmfData without trailing stamp.
                let lxmfBytes = data.count > LXStamper.stampSize
                    ? data.prefix(data.count - LXStamper.stampSize)
                    : data
                responseMessages.append(.bytes(Data(lxmfBytes)))
                cumulative += msgSize + perMsgOverhead
            }
        }

        // Fix the counter asymmetry (Received is taken under lock; Served must be too).
        lock.lock(); clientPropagationMessagesServed += responseMessages.count; lock.unlock()
        return .array(responseMessages)
    }

    // MARK: - Inbound message ingestion

    /// Ingest a new LXMF message arriving at the propagation destination (from a client or peer).
    ///
    /// Validates the stamp, stores the message, and queues it for peer distribution.
    ///
    /// Mirrors Python's `LXMRouter.lxmf_propagation()`.
    ///
    /// - Parameters:
    ///   - lxmfData: Raw LXMF bytes (without appended stamp).
    ///   - stampValue: Pre-validated stamp value.
    ///   - stamp: The 32-byte proof-of-work stamp.
    @discardableResult
    public func ingestPropagatedLXM(lxmfData: Data, stampValue: Int, stamp: Data) -> PropagationEntry? {
        let transientID = Hashes.fullHash(lxmfData)
        lock.lock(); let isDup = propagationEntries[transientID] != nil; lock.unlock()
        guard !isDup else { return nil } // duplicate (addToMessageStore re-checks under lock)

        let entry = addToMessageStore(lxmfData: lxmfData, transientID: transientID,
                                      stampValue: stampValue, stamp: stamp)
        if entry != nil { enqueueForPeerDistribution(transientID: transientID) }
        return entry
    }

    // MARK: - Persistence

    /// Persist the current set of peers to disk.
    public func savePeers() {
        guard let sp = storagePath else { return }
        // Snapshot the peer set under the lock; serialize (peer.toBytes self-locks via
        // the propagationEntries accessors) + write OUTSIDE the lock.
        lock.lock(); let peers = Array(self.peers.values); lock.unlock()
        let peerList = MsgPack.Value.array(peers.map { .bytes($0.toBytes()) })
        let data     = MsgPack.encode(peerList)
        // Atomic write (temp file + rename) so a crash mid-write can't leave a
        // truncated/corrupt peers file. Python (LXMF 1.0.2): write temp + os.replace.
        try? data.write(to: URL(fileURLWithPath: sp + "/peers"), options: .atomic)
    }

    /// Persist node statistics to disk.
    public func saveNodeStats() {
        guard let sp = storagePath else { return }
        lock.lock()
        let rcv   = clientPropagationMessagesReceived
        let srv   = clientPropagationMessagesServed
        let unpIn = unpeeredPropagationIncoming
        let unpRx = unpeeredPropagationRxBytes
        lock.unlock()
        let pairs: [(MsgPack.Value, MsgPack.Value)] = [
            (.string("client_propagation_messages_received"), .int(Int64(rcv))),
            (.string("client_propagation_messages_served"),   .int(Int64(srv))),
            (.string("unpeered_propagation_incoming"),        .int(Int64(unpIn))),
            (.string("unpeered_propagation_rx_bytes"),        .int(Int64(unpRx))),
        ]
        let data = MsgPack.encode(.map(pairs))
        // Atomic write so a crash can't corrupt node_stats. Python (LXMF 1.0.2).
        try? data.write(to: URL(fileURLWithPath: sp + "/node_stats"), options: .atomic)
    }

    // MARK: - Client state persistence
    //
    // Mirrors Python LXMRouter, which persists these across restarts under
    // storagepath. The Swift structures differ (e.g. a Set rather than a
    // timestamped dict), so the on-disk encoding is Swift-native msgpack rather
    // than byte-compatible with Python's files — the goal is restart durability,
    // and these files are always local to a single node. All writes are atomic.

    /// Load all persisted client state. Called automatically when `storagePath`
    /// is set. Safe to call repeatedly; missing/corrupt files are ignored.
    public func loadPersistedClientState() {
        loadLocallyDeliveredTransientIDs()
        loadLocallyProcessedTransientIDs()
        loadOutboundStampCosts()
        loadAvailableTickets()
    }

    /// Persist the set of transient ids we've already delivered locally, so a
    /// restart doesn't re-deliver duplicates. Python: `local_deliveries`.
    public func saveLocallyDeliveredTransientIDs() {
        guard let sp = storagePath else { return }
        lock.lock(); let snapshot = locallyDeliveredTransientIDs; lock.unlock()
        // Python persists this as a msgpack dict {transient_id: timestamp}; the
        // port previously wrote a bare array, which had nowhere to put the
        // timestamp the expiry job needs.
        let value = MsgPack.Value.map(snapshot.map { (MsgPack.Value.bytes($0.key), MsgPack.Value.double($0.value)) })
        try? MsgPack.encode(value).write(
            to: URL(fileURLWithPath: sp + "/local_deliveries"), options: .atomic)
    }

    private func loadLocallyDeliveredTransientIDs() {
        guard let sp = storagePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: sp + "/local_deliveries")),
              let decoded = try? MsgPack.decode(data) else { return }
        var loaded: [Data: TimeInterval] = [:]
        switch decoded {
        case .map(let pairs):
            for (k, v) in pairs {
                guard case .bytes(let id) = k else { continue }
                loaded[id] = v.asDouble ?? Date().timeIntervalSince1970
            }
        case .array(let items):
            // Legacy format written by earlier versions of this port: a bare
            // array with no timestamps. Stamp them as of now rather than
            // discarding the file, which would re-deliver every message the
            // node had already seen.
            let now = Date().timeIntervalSince1970
            for item in items { if case .bytes(let b) = item { loaded[b] = now } }
        default:
            return
        }
        lock.lock(); locallyDeliveredTransientIDs = loaded; lock.unlock()
        // Python reaps immediately after loading, so a long-idle node does not
        // carry an expired cache until the first interval elapses.
        cleanTransientIDCaches()
    }

    /// Persist the propagation-node tombstone cache.
    /// Python: `save_locally_processed_transient_ids`.
    public func saveLocallyProcessedTransientIDs() {
        guard let sp = storagePath else { return }
        lock.lock(); let snapshot = locallyProcessedTransientIDs; lock.unlock()
        let value = MsgPack.Value.map(snapshot.map { (MsgPack.Value.bytes($0.key), MsgPack.Value.double($0.value)) })
        try? MsgPack.encode(value).write(
            to: URL(fileURLWithPath: sp + "/locally_processed"), options: .atomic)
    }

    private func loadLocallyProcessedTransientIDs() {
        guard let sp = storagePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: sp + "/locally_processed")),
              case .map(let pairs) = (try? MsgPack.decode(data)) ?? .nil else { return }
        var loaded: [Data: TimeInterval] = [:]
        for (k, v) in pairs {
            guard case .bytes(let id) = k else { continue }
            loaded[id] = v.asDouble ?? Date().timeIntervalSince1970
        }
        lock.lock(); locallyProcessedTransientIDs = loaded; lock.unlock()
    }

    /// Expire transient IDs older than `transientIDCacheExpiry` from both
    /// caches. Mirrors Python's `LXMRouter.clean_transient_id_caches()`.
    func cleanTransientIDCaches() {
        let now = Date().timeIntervalSince1970
        let cutoff = now - LXMRouter.transientIDCacheExpiry
        lock.lock()
        locallyDeliveredTransientIDs = locallyDeliveredTransientIDs.filter { $0.value > cutoff }
        locallyProcessedTransientIDs = locallyProcessedTransientIDs.filter { $0.value > cutoff }
        lock.unlock()
    }

    /// Persist learned outbound stamp costs, so they survive a restart.
    /// Python: `outbound_stamp_costs`.
    public func saveOutboundStampCosts() {
        guard let sp = storagePath else { return }
        lock.lock(); let snapshot = outboundStampCosts; lock.unlock()
        let pairs = snapshot.map { (MsgPack.Value.bytes($0.key), MsgPack.Value.int(Int64($0.value))) }
        try? MsgPack.encode(.map(pairs)).write(
            to: URL(fileURLWithPath: sp + "/outbound_stamp_costs"), options: .atomic)
    }

    private func loadOutboundStampCosts() {
        guard let sp = storagePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: sp + "/outbound_stamp_costs")),
              case .map(let pairs) = (try? MsgPack.decode(data)) ?? .nil else { return }
        var loaded: [Data: Int] = [:]
        for (k, v) in pairs {
            guard case .bytes(let key) = k else { continue }
            switch v {
            case .int(let n):  loaded[key] = Int(n)
            case .uint(let n): loaded[key] = Int(n)
            default: break
            }
        }
        lock.lock(); outboundStampCosts = loaded; lock.unlock()
    }

    /// Persist available inbound/outbound tickets and last-delivery timestamps.
    /// Python: `available_tickets` (`{outbound, inbound, last_deliveries}`).
    public func saveAvailableTickets() {
        guard let sp = storagePath else { return }
        lock.lock()
        let ob = outboundTickets; let ib = inboundTickets_; let ld = lastDeliveries
        lock.unlock()
        // outbound: { dest: [expiry, ticket] }
        let obValue = MsgPack.Value.map(ob.map { (dest, entry) in
            (MsgPack.Value.bytes(dest), MsgPack.Value.array([.double(entry.expiry), .bytes(entry.ticket)]))
        })
        // inbound: { dest: { ticket: expiry } }
        let ibValue = MsgPack.Value.map(ib.map { (dest, tickets) in
            (MsgPack.Value.bytes(dest),
             MsgPack.Value.map(tickets.map { (t, e) in (MsgPack.Value.bytes(t), MsgPack.Value.double(e)) }))
        })
        // last_deliveries: { dest: timestamp }
        let ldValue = MsgPack.Value.map(ld.map { (dest, ts) in
            (MsgPack.Value.bytes(dest), MsgPack.Value.double(ts))
        })
        let root = MsgPack.Value.map([
            (.string("outbound"),        obValue),
            (.string("inbound"),         ibValue),
            (.string("last_deliveries"), ldValue),
        ])
        try? MsgPack.encode(root).write(
            to: URL(fileURLWithPath: sp + "/available_tickets"), options: .atomic)
    }

    private func loadAvailableTickets() {
        guard let sp = storagePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: sp + "/available_tickets")),
              case .map(let sections) = (try? MsgPack.decode(data)) ?? .nil else { return }
        var ob: [Data: (expiry: TimeInterval, ticket: Data)] = [:]
        var ib: [Data: [Data: TimeInterval]] = [:]
        var ld: [Data: TimeInterval] = [:]
        func asDouble(_ v: MsgPack.Value) -> Double? {
            switch v {
            case .double(let d): return d
            case .int(let n):    return Double(n)
            case .uint(let n):   return Double(n)
            default:             return nil
            }
        }
        for (section, value) in sections {
            guard case .string(let name) = section, case .map(let entries) = value else { continue }
            switch name {
            case "outbound":
                for (k, v) in entries {
                    guard case .bytes(let dest) = k, case .array(let arr) = v, arr.count == 2,
                          let expiry = asDouble(arr[0]), case .bytes(let ticket) = arr[1] else { continue }
                    ob[dest] = (expiry: expiry, ticket: ticket)
                }
            case "inbound":
                for (k, v) in entries {
                    guard case .bytes(let dest) = k, case .map(let tickets) = v else { continue }
                    var m: [Data: TimeInterval] = [:]
                    for (tk, te) in tickets {
                        if case .bytes(let ticket) = tk, let e = asDouble(te) { m[ticket] = e }
                    }
                    ib[dest] = m
                }
            case "last_deliveries":
                for (k, v) in entries {
                    if case .bytes(let dest) = k, let ts = asDouble(v) { ld[dest] = ts }
                }
            default: break
            }
        }
        lock.lock()
        outboundTickets = ob; inboundTickets_ = ib; lastDeliveries = ld
        lock.unlock()
    }

    // MARK: - Stamp value query helpers for peers

    /// Stamp value of a stored message.
    public func getStampValue(transientID: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        return propagationEntries[transientID]?.stampValue ?? 0
    }

    /// Receive timestamp (weight) of a stored message.
    public func getWeight(transientID: Data) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return propagationEntries[transientID]?.received ?? 0
    }

    /// File size of a stored message.
    public func getSize(transientID: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        return propagationEntries[transientID]?.msgSize ?? 0
    }

    /// Reset delivery timers for all pending propagated messages and trigger
    /// outbound processing. Called when the configured propagation node announces.
    /// Mirrors Python `Handlers.PropagationNodeAnnounceHandler` (LXMF 0.9.9).
    internal func triggerPropagatedOutbound() {
        lock.lock()
        let propagated = pendingOutbound.filter { $0.desiredMethod == .propagated }
        lock.unlock()
        for msg in propagated { msg.nextDeliveryAttempt = 0 }
        if !propagated.isEmpty {
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.processOutbound() }
        }
    }
}

// MARK: - Internal announce handlers

private final class DeliveryAnnounceHandler: AnnounceHandler {
    let aspectFilter: String? = APP_NAME + ".delivery"
    weak var router: LXMRouter?

    init(router: LXMRouter) { self.router = router }

    func receivedAnnounce(destinationHash: Data, identity: Identity, appData: Data?) {
        // Store the outbound stamp cost from the delivery announce.
        // Mirrors Python's LXMFDeliveryAnnounceHandler.received_announce → update_stamp_cost.
        let stampCost = stampCostFromAppData(appData)
        if let cost = stampCost {
            router?.setOutboundStampCost(destinationHash: destinationHash, stampCost: cost)
        }
        router?.handleAnnounceForDestination(destinationHash)
    }
}

/// Listens for announces from the configured outbound propagation node.
/// When the configured PN announces, triggers outbound processing for any
/// pending propagated messages so they are sent without waiting for the
/// next retry timer. Mirrors Python `Handlers.PropagationNodeAnnounceHandler`
/// (outbound processing trigger added in LXMF 0.9.9 / a8505ea).
private final class PropagationNodeAnnounceHandler: AnnounceHandler {
    let aspectFilter: String? = APP_NAME + ".propagation"
    weak var router: LXMRouter?

    init(router: LXMRouter) { self.router = router }

    func receivedAnnounce(destinationHash: Data, identity: Identity, appData: Data?) {
        guard let router else { return }
        // Only act if this announce is from our configured outbound PN.
        guard router.outboundPropagationNode == destinationHash else { return }
        guard propagationNodeAnnounceDataIsValid(appData) else { return }
        router.triggerPropagatedOutbound()
    }
}

// MARK: - msgpack numeric coercion

extension MsgPack.Value {
    /// Read a msgpack number as a `Double`, regardless of whether the encoder
    /// wrote it as a float, a signed int, or an unsigned int. Timestamps
    /// round-trip through all three depending on the writer, so every reader of
    /// a persisted timestamp needs this.
    var asDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let n):    return Double(n)
        case .uint(let n):   return Double(n)
        default:             return nil
        }
    }
}
