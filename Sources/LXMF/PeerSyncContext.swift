import Foundation
import ReticulumSwift

/// Everything an outbound peer sync needs from the outside world, resolved once per attempt.
///
/// The outbound half of the propagation protocol lives on `LXMPeer`, but the router owns the
/// transport (`private let transport`), the local identity and the message store. Before this
/// existed, `LXMPeer.sync()` could not dial anything, and the port stopped at a comment saying so
/// (`swift_devel/bugs/054`).
///
/// Two properties keep it a seam rather than a convenience:
///
/// - **No defaulted members and no back-pointer to the router.** A future dependency cannot be
///   quietly acquired inside the peer; it has to be added here, which forces the single
///   construction site — `LXMRouter.makePeerSyncContext(for:)` — to supply it.
/// - **Resolved from `peer.destinationHash`, always.** Python resolves the peer's identity twice,
///   in the constructor and again late in `sync()`, and the late one reads an unqualified
///   `destination_hash` (`LXMPeer.py:253`, `:305`) — a `NameError` that only fires for a peer
///   whose identity was unknown at construction. There is no Swift analogue because there is one
///   resolution and it takes its argument from the peer.
///
/// Mirrors the state Python's `LXMPeer` holds directly: `self.identity` / `self.destination`
/// (`LXMPeer.py:220-225`), `self.router.*` and the file reads at `:459-464`.
struct PeerSyncContext {

    /// This node's identity — the *sender* half of the peering material, and what the sync link
    /// identifies as (`LXMPeer.py:535`).
    let routerIdentity: Identity

    /// The peer's identity — the *receiver* half of the peering material (`LXMPeer.py:258`).
    let peerIdentity: Identity

    /// The peer's propagation destination, the one the sync link is opened to.
    let destination: Destination

    /// The transport the link is dialled on. LXMF is constructed with an explicit transport, so
    /// this is never `Reticulum.shared`.
    let transport: Transport

    /// Injected so a test can pin a timestamp without stubbing the clock globally.
    let now: () -> TimeInterval

    /// The stored message file for a transient ID, read verbatim off disk — LXMF bytes with the
    /// 32-byte propagation stamp still attached, because the receiver splits it back off to
    /// validate it. `nil` when the file has vanished, which Python skips silently (`:459-464`).
    let messageBytes: (Data) -> Data?

    /// Whether the message store still holds this transient ID. Python indexes
    /// `propagation_entries[transient_id]` directly (`:438`, `:451`) and raises if it does not.
    let entryExists: (Data) -> Bool

    /// The offer ordering key — `priorityWeight * ageWeight * size` (`LXMRouter.py:1056-1067`).
    let weight: (Data) -> Double

    /// Stored size in bytes, for the per-message and per-sync transfer limits.
    let size: (Data) -> Int

    /// The message's propagation stamp value, against which the peer's minimum accepted cost is
    /// tested before it is offered at all.
    let stampValue: (Data) -> Int

    /// Break the peering. Called when the peer answers `ERROR_NO_ACCESS` (`LXMPeer.py:416-419`).
    let unpeer: (Data) -> Void

    /// How long to postpone after `ERROR_THROTTLED` — the router's `PN_STAMP_THROTTLE`.
    let throttleWait: TimeInterval
}
