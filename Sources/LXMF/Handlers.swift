import Foundation
import ReticulumSwift

// MARK: - LXMFDeliveryAnnounceHandler

/// Handles announces on the `lxmf.delivery` aspect.
///
/// When a delivery destination announces itself, this handler:
/// 1. Updates the known outbound stamp cost for that destination.
/// 2. Resets delivery timers for any pending outbound messages addressed
///    to that destination, triggering an immediate delivery attempt.
///
/// Mirrors Python `LXMF.Handlers.LXMFDeliveryAnnounceHandler`.
public final class LXMFDeliveryAnnounceHandler: AnnounceHandler {

    // MARK: AnnounceHandler conformance

    /// Aspect filter that selects delivery announcements.
    /// Python: `self.aspect_filter = APP_NAME + ".delivery"`.
    public let aspectFilter: String? = APP_NAME + ".delivery"

    /// Whether this handler should receive path-response announces.
    /// Python: `self.receive_path_responses = True`.
    public let receivePathResponses: Bool = true

    // MARK: State

    /// The router whose outbound queue this handler triggers.
    public weak var router: LXMRouter?

    // MARK: Initialisation

    /// Create a delivery announce handler associated with `router`.
    public init(router: LXMRouter) {
        self.router = router
    }

    // MARK: Handling

    /// Called when a delivery destination announces.
    ///
    /// Mirrors `LXMFDeliveryAnnounceHandler.received_announce()` in Python:
    /// updates the stamp cost and triggers outbound delivery for matching messages.
    public func receivedAnnounce(destinationHash: Data,
                                  identity: Identity,
                                  appData: Data?) {
        guard let router else { return }

        // Update the known stamp cost for this destination.
        if let cost = stampCostFromAppData(appData) {
            router.setOutboundStampCost(destinationHash: destinationHash, stampCost: cost)
        }

        // Trigger immediate delivery for pending outbound messages to this destination.
        router.handleAnnounceForDestination(destinationHash)
    }
}

// MARK: - LXMFPropagationAnnounceHandler

/// Handles announces on the `lxmf.propagation` aspect.
///
/// When the configured outbound propagation node announces, this handler resets
/// delivery timers for all pending propagated messages and triggers outbound
/// processing.
///
/// Mirrors Python `LXMF.Handlers.LXMFPropagationAnnounceHandler`.
public final class LXMFPropagationAnnounceHandler: AnnounceHandler {

    // MARK: AnnounceHandler conformance

    /// Aspect filter that selects propagation node announcements.
    /// Python: `self.aspect_filter = APP_NAME + ".propagation"`.
    public let aspectFilter: String? = APP_NAME + ".propagation"

    /// Whether this handler should receive path-response announces.
    /// Python: `self.receive_path_responses = True`.
    public let receivePathResponses: Bool = true

    // MARK: State

    /// The router whose propagated outbound queue this handler triggers.
    public weak var router: LXMRouter?

    // MARK: Initialisation

    /// Create a propagation announce handler associated with `router`.
    public init(router: LXMRouter) {
        self.router = router
    }

    // MARK: Handling

    /// Called when a propagation node announces.
    ///
    /// Mirrors `LXMFPropagationAnnounceHandler.received_announce()` in Python:
    /// if the announce is from the configured outbound PN and the announce data
    /// is valid, resets delivery timers for pending propagated messages and
    /// triggers outbound processing.
    public func receivedAnnounce(destinationHash: Data,
                                  identity: Identity,
                                  appData: Data?) {
        guard let router else { return }
        // Only act when this announce is from our configured outbound PN.
        guard router.outboundPropagationNode == destinationHash else { return }
        guard propagationNodeAnnounceDataIsValid(appData) else { return }
        router.triggerPropagatedOutbound()
    }
}
