import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/055`, step 10 — the one consumer-side write Python has that encapsulation
/// would otherwise have taken away.
///
/// Making the lock-guarded properties read-only closed every unsynchronized write path, which is
/// the point. But Python's attributes are writable, and the question that decides whether this is
/// a parity break is not "does Python permit it" — it is "does any Python consumer *do* it".
///
/// Across the whole reference tree the answer is one line. `nomadnet`, `lxmd` and `LXMF`'s own
/// handlers between them assign to router or peer state exactly once from outside the owning
/// class:
///
/// ```python
/// # nomadnet/nomadnet/ui/textui/Network.py:1810-1822 — "sync selected peer now"
/// if time.time() > peer.last_sync_attempt + sync_grace:
///     peer.next_sync_attempt = time.time() - 1
///     threading.Thread(target=lambda: peer.sync(), daemon=True).start()
/// ```
///
/// Everything else Python's consumers do with these objects is a read, a constructor argument, or
/// a method call — all of which survive the change untouched.
///
/// So `LXMPeer` keeps exactly one public write path, expressed as the intent rather than as the
/// field assignment. These tests pin its behaviour to Python's line, including what it must *not*
/// do.
final class ConsumerWriteParityTests: XCTestCase {

    private func makePeer() -> LXMPeer {
        LXMPeer(router: LXMRouter(transport: Transport()),
                destinationHash: Data(repeating: 0xAA, count: LXMessage.destinationLength))
    }

    /// **Observed red before the fix** — as a compile error, `value of type 'LXMPeer' has no
    /// member 'requestImmediateSync'`, which is the strongest red an API-addition test gets. There
    /// is no way to write this test against the previous revision that both fails and compiles:
    /// the capability it asks for did not exist under any name.
    ///
    /// A peer that has just backed off is not eligible to sync. Python's NomadNet makes it
    /// eligible by pushing the deadline one second into the past (`Network.py:1818`).
    func testAPeerCanBeMadeEligibleToSyncImmediately() {
        let peer = makePeer()
        let now  = Date().timeIntervalSince1970

        // A peer mid-backoff: the sync gate is `now > nextSyncAttempt` (`LXMPeer.sync()`).
        peer.seedSyncState(nextSyncAttempt: now + 600, syncBackoff: 60)
        XCTAssertGreaterThan(peer.nextSyncAttempt, now,
                             "precondition: this peer is not yet eligible to sync")

        peer.requestImmediateSync()

        XCTAssertLessThan(peer.nextSyncAttempt, Date().timeIntervalSince1970,
                          """
                          the peer is still not eligible to sync. NomadNet's "sync now" action \
                          cannot be ported without this: it is the one consumer-side write in \
                          Python's entire LXMF surface (`Network.py:1818`).
                          """)
    }

    /// The limit of what it does, pinned so nobody makes it "more helpful" later.
    ///
    /// Python's line sets `next_sync_attempt` and nothing else. The accumulated backoff stays,
    /// because a manual sync is a one-off nudge and not a declaration that the peer is healthy —
    /// if this attempt fails too, `sync()` resumes stepping the backoff from where it was. Only a
    /// peer announce clears it (`LXMRouter.py:2017-2018`, Swift `clearSyncBackoff()`).
    func testRequestingAnImmediateSyncDoesNotClearTheAccumulatedBackoff() {
        let peer = makePeer()
        peer.seedSyncState(nextSyncAttempt: Date().timeIntervalSince1970 + 600, syncBackoff: 60)

        peer.requestImmediateSync()

        XCTAssertEqual(peer.syncBackoff, 60, accuracy: 0.001,
                       """
                       the backoff was reset. Python's "sync now" does not touch it \
                       (`Network.py:1818` assigns one field), so a peer that keeps failing would \
                       here be retried at the base interval forever instead of backing off.
                       """)
    }

    /// The caller's half of Python's idiom has to keep working too.
    ///
    /// NomadNet gates the action on `time.time() > peer.last_sync_attempt + sync_grace` — a read
    /// of a property this change made read-only. Read-only is not write-only-in-reverse: the whole
    /// design rests on reads staying free, and this is the read that a port of `Network.py` needs.
    func testTheGraceCheckPythonGatesTheActionOnIsStillReadable() {
        let peer = makePeer()
        let syncGrace: TimeInterval = 10
        let now = Date().timeIntervalSince1970

        peer.seedSyncState(lastSyncAttempt: now)
        XCTAssertFalse(now > peer.lastSyncAttempt + syncGrace,
                       "a peer that just attempted a sync is inside the grace window")

        peer.seedSyncState(lastSyncAttempt: now - (syncGrace + 1))
        XCTAssertTrue(Date().timeIntervalSince1970 > peer.lastSyncAttempt + syncGrace,
                      "the grace window has passed and the action should be offered")
    }
}
