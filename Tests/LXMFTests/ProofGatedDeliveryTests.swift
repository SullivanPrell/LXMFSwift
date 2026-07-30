import XCTest
import LXMF
import ReticulumSwift

/// A message is reported delivered only when the recipient proves it — `bugs/014`, task 5.1.
///
/// The reference takes the packet receipt returned by the send call and reaches DELIVERED, and
/// fires the application's delivery callback, only when the receiver's explicit proof validates
/// (`LXMessage.py:482-483`, `__mark_delivered` at `:563-568`). This port called `link.send(...)`
/// and, if it did not throw, set `.delivered` and fired `onDelivery` on the next line. Returning
/// from a send call is not evidence of delivery: the packet may be dropped by the very next hop,
/// and the sender's screen says it arrived.
///
/// **Why the existing test cannot fail.** `LXMRouterResourceTests.swift:183` asserts that the
/// delivery callback fires on a healthy loopback link. On a healthy link the proof always comes
/// back, so send-time firing and proof-time firing are indistinguishable — it passes identically
/// before and after this requirement is met. Both tests here are built so that they can only pass
/// if the gate is real: one never lets the message arrive at all, and the other lets the message
/// arrive but holds the proof back, so "delivered" and "received" are separated in time and can
/// be asserted against each other.
final class ProofGatedDeliveryTests: XCTestCase {

    // MARK: - A message that never arrives is not delivered

    /// Spec: "A lost message is not reported delivered."
    func testAMessageOverALinkThatDoesNotDeliverStaysSending() throws {
        let net = try LoopbackPair()

        // The link is up and stays up; only the LXMF payload is lost. This is the case the
        // reference's timeout path exists for, and the one a real network produces constantly —
        // a dropped packet, not a closed link.
        net.senderInterface.dropOutbound = { $0.destinationType == .link && $0.packetType == .data }

        var deliveryFired = false
        let message = try net.sendMessage(content: "into the void",
                                          onDelivery: { _ in deliveryFired = true })

        XCTAssertEqual(message.state, .sending,
                       "the message never arrived, so it cannot be past 'sending'")
        XCTAssertFalse(deliveryFired,
                       "the delivery callback fired for a message the peer never received")
    }

    /// Spec: "after the timeout the message is back in the outbound queue for another attempt"
    /// and "the link is torn down, matching the reference's timeout behaviour"
    /// (`LXMessage.py:616-621`).
    ///
    /// Slow by construction: the sweep that expires receipts runs on Transport's jobs loop at a
    /// fixed five-second interval, and driving it from a test would mean asserting against a
    /// mechanism the daemon does not use. So this waits for one real tick.
    func testATimedOutMessageReturnsToOutboundAndTearsTheLinkDown() throws {
        let net = try LoopbackPair()
        net.senderInterface.dropOutbound = { $0.destinationType == .link && $0.packetType == .data }
        try net.senderTransport.start()

        var deliveryFired = false
        let message = try net.sendMessage(content: "never acknowledged",
                                          onDelivery: { _ in deliveryFired = true })
        XCTAssertEqual(message.state, .sending)

        // Expire the receipt almost immediately; the sweep still has to notice it.
        let receipt = try XCTUnwrap(message.deliveryReceipt,
                                    "a link data packet must produce a receipt to time out at all")
        receipt.setTimeout(0.5)

        let returned = expectation(description: "message returned to outbound")
        net.poll(until: { message.state == .outbound }, fulfilling: returned, limit: 900)
        wait(for: [returned], timeout: 12.0)

        XCTAssertFalse(deliveryFired, "a timed-out message was never delivered")
        XCTAssertNotEqual(net.link?.status, .active,
                          "the reference tears the link down on timeout, because a proof that "
                          + "never returned is evidence about the link, not just the packet")
    }

    /// Spec: "The user interface reflects the true state" — "a retry after a timeout is visible
    /// rather than silent" (R3).
    ///
    /// `onDelivery` reports one terminal outcome, so an application wired only to it sees a
    /// message vanish into `.sending` and, on a timeout, nothing at all. This asserts the
    /// transitions themselves are observable, which is what the application needs to show a
    /// dwell and a retry honestly.
    func testEveryStateTransitionIsObservable() throws {
        let net = try LoopbackPair()
        net.senderInterface.dropOutbound = { $0.destinationType == .link && $0.packetType == .data }
        try net.senderTransport.start()

        // Locked: state changes arrive on whichever thread made them — the receipt's timeout
        // callback runs on a background queue — while the poller below reads concurrently.
        let observed = StateLog()
        let message = try net.sendMessage(content: "watch me",
                                          onStateChange: { observed.record($0.state) })

        XCTAssertEqual(observed.last, .sending, "the dwell must be reported when it begins")

        let receipt = try XCTUnwrap(message.deliveryReceipt)
        receipt.setTimeout(0.5)

        let retried = expectation(description: "retry observed")
        net.poll(until: { observed.last == .outbound }, fulfilling: retried, limit: 900)
        wait(for: [retried], timeout: 12.0)

        XCTAssertEqual(observed.suffix(2), [.sending, .outbound],
                       "an application wired to state changes sees the dwell and then the retry, "
                       + "instead of a message that silently stops moving")
    }

    // MARK: - Ordering, not occurrence

    /// Spec: "Delivery is reported after the proof, not before" — "the ordering is asserted, not
    /// merely the occurrence".
    ///
    /// The message is allowed through, so the receiver really does get it; only the proof is held.
    /// That splits the two events apart, so the assertion is about which one happened first
    /// rather than about whether the callback ever fires.
    func testDeliveryIsReportedAfterTheProofAndNotBefore() throws {
        let net = try LoopbackPair()

        let received = expectation(description: "receiver got the message")
        net.onReceive = { _ in received.fulfill() }

        // Hold the *data* proof travelling back towards the sender — context `.none`, which is
        // the same predicate the reference uses to decide a packet is receipt-worthy
        // (`Transport.py:1113-1124` excludes the KEEPALIVE…LRPROOF range). Holding every proof
        // would block the link handshake's own LRPROOF and no link would come up at all.
        net.receiverInterface.holdOutbound = { $0.packetType == .proof && $0.context == .none }

        var deliveryFired = false
        let message = try net.sendMessage(content: "prove it",
                                          onDelivery: { _ in deliveryFired = true })

        wait(for: [received], timeout: 2.0)

        // The receiver has the message in hand. The sender must still not claim delivery,
        // because nothing has come back to say so.
        XCTAssertFalse(deliveryFired,
                       "delivery was reported while the proof was still held — this is "
                       + "send-time firing, which a healthy loopback link hides")
        XCTAssertEqual(message.state, .sending)

        // Release the proof. Only now may the sender say delivered.
        net.receiverInterface.releaseHeld()

        let delivered = expectation(description: "delivery reported after the proof")
        net.poll(until: { deliveryFired }, fulfilling: delivered)
        wait(for: [delivered], timeout: 2.0)
        XCTAssertEqual(message.state, .delivered)
    }
}

/// Thread-safe log of observed state transitions.
private final class StateLog {
    private let lock = NSLock()
    private var states: [LXMessage.State] = []

    func record(_ state: LXMessage.State) { lock.lock(); states.append(state); lock.unlock() }
    var last: LXMessage.State? { lock.lock(); defer { lock.unlock() }; return states.last }
    func suffix(_ n: Int) -> [LXMessage.State] {
        lock.lock(); defer { lock.unlock() }; return Array(states.suffix(n))
    }
}

// MARK: - Test network

/// Two transports joined by a pair of loopback interfaces, either of which can drop or hold
/// selected packets.
///
/// Dropping and holding are what make this defect observable: every existing link test uses a
/// perfect channel, where a message is always proved the instant it is sent.
private final class LoopbackPair {
    let senderTransport = Transport()
    let receiverTransport = Transport()
    let senderInterface = GatedInterface(name: "sender")
    let receiverInterface = GatedInterface(name: "receiver")

    let senderIdentity = Identity()
    let receiverIdentity = Identity()
    let senderRouter: LXMRouter
    let receiverRouter: LXMRouter
    let receiverDestinationHash: Data

    var onReceive: ((LXMessage) -> Void)?
    /// The established sender-side link, so a test can assert on its status after a timeout.
    private(set) var link: Link?

    init() throws {
        senderInterface.paired = receiverInterface
        receiverInterface.paired = senderInterface
        senderTransport.register(interface: senderInterface)
        receiverTransport.register(interface: receiverInterface)

        let receiverDestination = try Destination(
            identity: receiverIdentity, direction: .in, kind: .single,
            appName: "lxmf", aspects: ["delivery"])
        receiverTransport.ownerIdentity = receiverIdentity
        receiverTransport.register(destination: receiverDestination)
        receiverDestinationHash = receiverDestination.hash

        senderRouter = LXMRouter(transport: senderTransport)
        receiverRouter = LXMRouter(transport: receiverTransport)
        try senderRouter.register(identity: senderIdentity, transport: senderTransport)
        try receiverRouter.register(identity: receiverIdentity, transport: receiverTransport)

        // Each side knows the other's identity, so nothing here is waiting on an announce.
        senderTransport.restore(identity: receiverIdentity, forDestination: receiverDestination.hash)
        let senderDestination = try Destination(
            identity: senderIdentity, direction: .in, kind: .single,
            appName: "lxmf", aspects: ["delivery"])
        receiverTransport.restore(identity: senderIdentity, forDestination: senderDestination.hash)
    }

    /// Bring up a link, hand it to the router, and send one small message over it.
    func sendMessage(content: String,
                     onDelivery: @escaping (LXMessage) -> Void = { _ in },
                     onStateChange: ((LXMessage) -> Void)? = nil) throws -> LXMessage {
        let receiverDestination = try Destination(
            identity: receiverIdentity, direction: .in, kind: .single,
            appName: "lxmf", aspects: ["delivery"])

        let established = XCTestExpectation(description: "link established")
        senderTransport.onLinkEstablished = { _ in established.fulfill() }
        receiverTransport.onLinkEstablished = { _ in }
        let link = try Link.initiate(destination: receiverDestination, transport: senderTransport)
        XCTWaiter().wait(for: [established], timeout: 2.0)
        self.link = link

        // Wire the responder side the way an inbound link is wired in production, so the
        // receiver's router actually parses what arrives.
        if let responder = receiverTransport.links[link.linkID!] {
            receiverTransport.registeredDestinations[receiverDestinationHash]?
                .onLinkEstablished?(responder)
        }
        receiverRouter.onMessageReceived = { [weak self] message in self?.onReceive?(message) }

        senderRouter.injectDirectLink(link, for: receiverDestinationHash)

        let senderDestination = try Destination(
            identity: senderIdentity, direction: .in, kind: .single,
            appName: "lxmf", aspects: ["delivery"])
        let message = LXMessage(
            destination: receiverDestination,
            source: senderDestination,
            content: Data(content.utf8),
            desiredMethod: .direct)
        message.onDelivery = onDelivery
        message.onStateChange = onStateChange
        try senderRouter.send(message)
        senderRouter.processOutbound()
        return message
    }

    /// Poll `condition` off the main queue until it holds, then fulfil.
    func poll(until condition: @escaping () -> Bool,
              fulfilling expectation: XCTestExpectation,
              limit: Int = 200) {
        DispatchQueue.global().async {
            for _ in 0..<limit {
                if condition() { expectation.fulfill(); return }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }
}

/// A loopback interface that can drop packets outright or hold them for later release.
private final class GatedInterface: Interface {
    let name: String
    var bitrate: Int = 1_000_000
    var isOnline: Bool = true
    var inboundHandler: ((Packet, any Interface) -> Void)?
    weak var paired: GatedInterface?

    /// Packets matching this are discarded, as a lossy hop would discard them. The link stays up.
    var dropOutbound: ((Packet) -> Bool)?
    /// Packets matching this are queued instead of delivered, until `releaseHeld()`.
    var holdOutbound: ((Packet) -> Bool)?

    private let lock = NSLock()
    private var held: [Data] = []

    init(name: String) { self.name = name }

    func send(_ packet: Packet) throws {
        if dropOutbound?(packet) == true { return }
        let raw = try packet.pack()
        if holdOutbound?(packet) == true {
            lock.lock(); held.append(raw); lock.unlock()
            return
        }
        deliver(raw)
    }

    func releaseHeld() {
        lock.lock()
        let queued = held
        held = []
        lock.unlock()
        for raw in queued { deliver(raw) }
    }

    private func deliver(_ raw: Data) {
        guard let copy = try? Packet.unpack(raw), let paired else { return }
        paired.inboundHandler?(copy, paired)
    }

    func start() throws {}
    func stop() {}
}
