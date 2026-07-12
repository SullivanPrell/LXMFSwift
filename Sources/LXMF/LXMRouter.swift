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

    /// Locally delivered transient IDs (for `has_message`).
    var locallyDeliveredTransientIDs: Set<Data> = []

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
    public var storagePath: String? = nil

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
            self?.processOutbound()
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

                // Validate signature immediately if source identity is known.
                // Otherwise defer: Python's backbone forwards announces in a separate
                // thread so the announce may arrive after the link data packet.
                // `deferDeliveryUntilSourceKnown` queues the message; the
                // DeliveryAnnounceHandler drains the queue when the announce arrives
                // (within 60 s fallback for unreachable senders).
                if let srcIdentity = self.transport.recall(identity: msg.sourceHash) {
                    msg.validateSignature(knownIdentity: srcIdentity)
                    self.finalizeInboundDelivery(msg)
                } else {
                    self.deferDeliveryUntilSourceKnown(msg)
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
        lock.lock(); defer { lock.unlock() }
        outboundTickets[destinationHash] = (expiry: expiry, ticket: ticket)
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
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970

        // Respect the minimum interval between ticket deliveries.
        if let lastDelivery = lastDeliveries[destinationHash],
           (now - lastDelivery) < LXMessage.ticketInterval { return nil }

        // Reuse an existing inbound ticket if it has enough validity remaining.
        if let existing = inboundTickets_[destinationHash] {
            for (ticket, ticketExpiry) in existing {
                let validityLeft = ticketExpiry - now
                if validityLeft > LXMessage.ticketRenew {
                    return (expiry: ticketExpiry, ticket: ticket)
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
        lock.lock(); defer { lock.unlock() }
        outboundStampCosts[destinationHash] = stampCost
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
        return locallyDeliveredTransientIDs.contains(transientID)
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
    /// Mirrors Python's `LXMRouter.ingest_lxm_uri(uri)`.
    public func ingestLXMURI(_ uri: String) throws {
        let msg = try LXMessage.fromURI(uri)
        msg.state = .delivered
        onMessageReceived?(msg)
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
            msg.state = .sending
            do {
                try link.send(packed)
                removePending(msg)
                msg.state = .delivered
                // Retain destination announce data (LXMF commit 8bdb434).
                _ = transport.retainDestinationData(msg.destinationHash)
                msg.onDelivery?(msg)
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
            }
        )
    }

    func handleMessageGetResponse(_ data: Data, receipt: RequestReceipt) {
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

            lock.lock(); locallyDeliveredTransientIDs.insert(transientID); lock.unlock()
            deliverInboundResource(destHash + plaintext)
        }

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
    public func deliverInboundResource(_ data: Data) {
        guard let msg = try? LXMessage.unpack(data) else { return }
        // Drop messages from blackholed source identities (LXMF commit 2ac2b10).
        if msg.sourceBlackholed { return }
        lock.lock()
        let isDelivery = deliveryDestinations[msg.destinationHash] != nil
        lock.unlock()
        guard isDelivery else { return }
        msg.incoming = true
        msg.state = .delivered

        if let srcIdentity = transport.recall(identity: msg.sourceHash) {
            msg.validateSignature(knownIdentity: srcIdentity)
            finalizeInboundDelivery(msg)
        } else {
            deferDeliveryUntilSourceKnown(msg)
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

    // MARK: - Deferred signature validation

    /// Queue a received message for deferred signature validation.
    ///
    /// When the sender's lxmf.delivery announce arrives, `handleAnnounceForDestination`
    /// will drain this queue, validate the signature with the now-known identity, and
    /// call `onMessageReceived`. A 10-second fallback timer delivers the message
    /// unverified if no announce arrives within that window.
    ///
    /// This handles the race where Python's backbone forwards announces in a separate
    /// thread, so the announce may arrive after the message on the link.
    private func deferDeliveryUntilSourceKnown(_ msg: LXMessage) {
        lock.lock()
        pendingSignatureValidation.append((message: msg, received: Date()))
        lock.unlock()

        // Fallback: deliver unverified after 60 s in case the source announce
        // never arrives. In practice the announce propagates within a few seconds
        // on a healthy network, but RNS announce rate-limiting on intermediate
        // backbone nodes can delay forwarding by 10–20 s or more when there is
        // competing announce traffic. 60 s gives ample room while still
        // eventually delivering to the application.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60.0) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let wasPresent = self.pendingSignatureValidation.contains(where: { $0.message === msg })
            if wasPresent { self.pendingSignatureValidation.removeAll { $0.message === msg } }
            self.lock.unlock()
            if wasPresent {
                msg.unverifiedReason = .sourceUnknown
                self.finalizeInboundDelivery(msg)
            }
        }
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
            // Source identity not yet known — defer until announce arrives.
            deferDeliveryUntilSourceKnown(msg)
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
            lock.lock(); locallyDeliveredTransientIDs.insert(tid); lock.unlock()
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

        // Index existing messages in the store.
        propagationEntries.removeAll()
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

                propagationEntries[transientID] = PropagationEntry(
                    destinationHash: destHash,
                    filePath:       filePath,
                    received:       ts,
                    msgSize:        msgSize,
                    handledPeers:   [],
                    unhandledPeers: [],
                    stampValue:     sv
                )
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
                    peers[peer.destinationHash] = peer
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
            let remoteHash = link.remoteIdentity?.hash
            return self.handleOfferRequest(data: requestData,
                                           remoteIdentityHash: remoteHash,
                                           linkID: ObjectIdentifier(link))
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
            link.onResourceConcluded = { [weak self] data, _, _ in
                self?.handleInboundPropagationResource(data)
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
    public func handleInboundPropagationResource(_ data: Data) {
        guard case .array(let outer) = (try? MsgPack.decode(data)) ?? .nil,
              outer.count >= 2,
              case .array(let messages) = outer[1] else { return }

        let transientList: [Data] = messages.compactMap {
            if case .bytes(let b) = $0 { return Data(b) }
            return nil
        }

        let minCost = max(0, propagationStampCost - propagationStampCostFlexibility)
        let validated = LXStamper.validatePNStamps(transientList: transientList, targetCost: minCost)
        for entry in validated {
            lock.lock(); clientPropagationMessagesReceived += 1; lock.unlock()
            _ = ingestPropagatedLXM(lxmfData: entry.lxmfData,
                                    stampValue: entry.stampValue,
                                    stamp:      entry.stamp)
        }
    }

    // MARK: - Message store

    /// Total bytes currently used by the message store.
    /// Returns nil when not acting as a propagation node.
    /// Python: `LXMRouter.message_storage_size()`.
    public func messageStorageSize() -> Int? {
        guard isPropagationNode else { return nil }
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

        // Existing entry? Skip.
        if propagationEntries[transientID] != nil { return propagationEntries[transientID] }

        let received  = Date().timeIntervalSince1970
        let hexID     = transientID.map { String(format: "%02x", $0) }.joined()
        let filename  = "\(hexID)_\(received)_\(stampValue)"
        let filePath  = mp + "/" + filename

        // Write lxmfData + stamp to disk.
        var fileBytes = lxmfData
        fileBytes.append(stamp)
        guard (try? fileBytes.write(to: URL(fileURLWithPath: filePath))) != nil else { return nil }

        let destHash = Data(lxmfData.prefix(LXMessage.destinationLength))
        let entry    = PropagationEntry(
            destinationHash: destHash,
            filePath:       filePath,
            received:       received,
            msgSize:        fileBytes.count,
            handledPeers:   [],
            unhandledPeers: peers.keys.map { $0 },  // all peers need this message
            stampValue:     stampValue
        )
        propagationEntries[transientID] = entry
        return entry
    }

    /// Remove a message from the store (delete file + entry).
    /// Python: `os.unlink(filepath)` + `propagation_entries.pop(transient_id)`.
    public func removeFromMessageStore(transientID: Data) {
        guard let entry = propagationEntries[transientID] else { return }
        try? FileManager.default.removeItem(atPath: entry.filePath)
        propagationEntries.removeValue(forKey: transientID)
    }

    /// Clean the message store, removing the oldest messages when over the storage limit.
    /// Mirrors Python's `LXMRouter.clean_message_store()`.
    public func cleanMessageStore() {
        guard isPropagationNode else { return }
        guard let limit = messageStorageLimit else { return }

        var currentSize = messageStorageSize() ?? 0
        guard currentSize > limit else { return }

        // Sort by receive time ascending (oldest first)
        let sorted = propagationEntries.sorted { $0.value.received < $1.value.received }
        for (tid, entry) in sorted {
            guard currentSize > limit else { break }
            currentSize -= entry.msgSize
            removeFromMessageStore(transientID: tid)
        }
    }

    // MARK: - Peer management

    /// Add a peer propagation node.
    /// Python: `self.peers[destination_hash] = LXMPeer(...)`.
    @discardableResult
    public func addPeer(destinationHash: Data,
                        syncStrategy: LXMSyncStrategy = LXMPeer.defaultSyncStrategy) -> LXMPeer {
        if let existing = peers[destinationHash] { return existing }
        let peer = LXMPeer(router: self, destinationHash: destinationHash,
                           syncStrategy: syncStrategy)
        // All existing messages are unhandled for the new peer.
        for tid in propagationEntries.keys {
            peer.addUnhandledMessage(tid)
        }
        peers[destinationHash] = peer
        return peer
    }

    /// Remove a peer from the peering table.
    public func removePeer(destinationHash: Data) {
        guard let peer = peers.removeValue(forKey: destinationHash) else { return }
        // Clean up that peer's references from all propagation entries.
        for tid in propagationEntries.keys {
            propagationEntries[tid]!.handledPeers.removeAll { $0 == peer.destinationHash }
            propagationEntries[tid]!.unhandledPeers.removeAll { $0 == peer.destinationHash }
        }
    }

    // MARK: - Distribution queue

    /// Notify all peers that a new message has arrived and queue it for distribution.
    /// Python: `LXMRouter.peer_distribution_queue.append(transient_id)` + per-peer queue.
    public func enqueueForPeerDistribution(transientID: Data) {
        guard !peerDistributionQueue.contains(transientID) else { return }
        peerDistributionQueue.append(transientID)
    }

    /// Flush the peer distribution queue — mark new messages as unhandled for all peers.
    /// Python: `LXMRouter.flush_peer_distribution_queue()`.
    public func flushPeerDistributionQueue() {
        guard isPropagationNode, !peerDistributionQueue.isEmpty else { return }
        while !peerDistributionQueue.isEmpty {
            let tid = peerDistributionQueue.removeFirst()
            for peer in peers.values {
                peer.queueUnhandledMessage(tid)
            }
        }
        for peer in peers.values { peer.processQueues() }
    }

    /// Attempt to sync with all peers.
    /// Python: `LXMRouter.sync_peers()`.
    public func syncPeers() {
        guard isPropagationNode else { return }
        for peer in peers.values { peer.sync() }
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
    ///   - remoteIdentityHash: Hash of the requesting peer's identity (nil if unidentified).
    ///   - linkID: ObjectIdentifier for the requesting link.
    /// - Returns: Response value:
    ///   - `LXMPeerError.noIdentity` if not identified
    ///   - `false` (MsgPack.Value.bool) if we already have all offered messages
    ///   - `true`  if we want all offered messages
    ///   - `[Data]` list of wanted transient IDs
    public func handleOfferRequest(data: MsgPack.Value,
                                   remoteIdentityHash: Data?,
                                   linkID: ObjectIdentifier) -> MsgPack.Value {
        guard isPropagationNode else { return .int(Int64(LXMPeerError.noAccess.rawValue)) }
        guard let remoteHash = remoteIdentityHash else {
            return .int(Int64(LXMPeerError.noIdentity.rawValue))
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

        validatedPeerLinks[linkID] = true

        // Build the wanted IDs list — messages the peer offered that we don't have yet.
        let wantedIDs = offeredIDs.filter { propagationEntries[$0] == nil }

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
            let available = propagationEntries.compactMap { (tid, entry) -> (Data, Int)? in
                entry.destinationHash == destHash ? (tid, entry.msgSize) : nil
            }
            let sorted = available.sorted { $0.1 < $1.1 }
            return .array(sorted.map { .bytes($0.0) })
        }

        // Process "have" list — client already has these, delete from store.
        if let have = haveList {
            for tid in have {
                if propagationEntries[tid]?.destinationHash == destHash {
                    removeFromMessageStore(transientID: tid)
                }
            }
        }

        // Process "want" list — send requested message bytes.
        var responseMessages: [MsgPack.Value] = []
        let perMsgOverhead = 16
        var cumulative     = 24

        if let want = wantList {
            for tid in want {
                guard let entry = propagationEntries[tid],
                      entry.destinationHash == destHash else { continue }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: entry.filePath)) else { continue }

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

        clientPropagationMessagesServed += responseMessages.count
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
        guard propagationEntries[transientID] == nil else { return nil } // duplicate

        let entry = addToMessageStore(lxmfData: lxmfData, transientID: transientID,
                                      stampValue: stampValue, stamp: stamp)
        if entry != nil { enqueueForPeerDistribution(transientID: transientID) }
        return entry
    }

    // MARK: - Persistence

    /// Persist the current set of peers to disk.
    public func savePeers() {
        guard let sp = storagePath else { return }
        let peerList = MsgPack.Value.array(peers.values.map { .bytes($0.toBytes()) })
        let data     = MsgPack.encode(peerList)
        // Atomic write (temp file + rename) so a crash mid-write can't leave a
        // truncated/corrupt peers file. Python (LXMF 1.0.2): write temp + os.replace.
        try? data.write(to: URL(fileURLWithPath: sp + "/peers"), options: .atomic)
    }

    /// Persist node statistics to disk.
    public func saveNodeStats() {
        guard let sp = storagePath else { return }
        let pairs: [(MsgPack.Value, MsgPack.Value)] = [
            (.string("client_propagation_messages_received"), .int(Int64(clientPropagationMessagesReceived))),
            (.string("client_propagation_messages_served"),   .int(Int64(clientPropagationMessagesServed))),
            (.string("unpeered_propagation_incoming"),        .int(Int64(unpeeredPropagationIncoming))),
            (.string("unpeered_propagation_rx_bytes"),        .int(Int64(unpeeredPropagationRxBytes))),
        ]
        let data = MsgPack.encode(.map(pairs))
        // Atomic write so a crash can't corrupt node_stats. Python (LXMF 1.0.2).
        try? data.write(to: URL(fileURLWithPath: sp + "/node_stats"), options: .atomic)
    }

    // MARK: - Stamp value query helpers for peers

    /// Stamp value of a stored message.
    public func getStampValue(transientID: Data) -> Int {
        propagationEntries[transientID]?.stampValue ?? 0
    }

    /// Receive timestamp (weight) of a stored message.
    public func getWeight(transientID: Data) -> TimeInterval {
        propagationEntries[transientID]?.received ?? 0
    }

    /// File size of a stored message.
    public func getSize(transientID: Data) -> Int {
        propagationEntries[transientID]?.msgSize ?? 0
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
