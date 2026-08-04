import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/019` — the periodic job loop runs every routine the reference runs, on the
/// reference's schedule.
///
/// Python's `jobs()` (`LXMF/LXMRouter.py:880-911`) dispatches ten calls, each on its own interval,
/// four of them only when the node is a propagation node. Swift's timer ran three of them.
///
/// The assertions are about the **schedule**, not about a set of calls made once. A test that
/// drove the loop and checked "everything ran" would pass against a loop that ran everything every
/// tick, which is a different defect — `sync_peers` every 4 seconds instead of every 24 would dial
/// every peer six times as often as the reference.
final class LXMRouterJobsTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_jobs_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir,
                                                 withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    /// `LXMRouter.py:871-911`, transcribed: routine name, its interval in ticks, and whether the
    /// reference gates it on being a propagation node.
    private static let reference: [(name: String, interval: Int, propagationNodeOnly: Bool)] = [
        ("processOutbound",         1,   false),   // :884-885, JOB_OUTBOUND_INTERVAL
        ("processDeferredStamps",   1,   false),   // :887-888, JOB_STAMPS_INTERVAL
        ("cleanLinks",              1,   false),   // :890-891, JOB_LINKS_INTERVAL
        ("cleanResourceTracking",   2,   false),   // :893-894, JOB_RESOURCE_INTERVAL
        ("cleanTransientIDCaches",  60,  false),   // :896-897, JOB_TRANSIENT_INTERVAL
        ("cleanMessageStore",       120, true),    // :899-900, JOB_STORE_INTERVAL
        ("flushQueues",             6,   true),    // :902-903, JOB_PEERINGEST_INTERVAL
        ("rotatePeers",             336, true),    // :905-906, JOB_ROTATE_INTERVAL = 56 × 6
        ("syncPeers",               6,   true),    // :908-909, JOB_PEERSYNC_INTERVAL
        ("cleanThrottledPeers",     6,   false),   // :910, shares the slot, *not* PN-gated
    ]

    // MARK: - The schedule

    func testTheScheduleNamesEveryReferenceRoutine() {
        let declared = Set(LXMRouter.jobSchedule.map(\.name))
        let expected = Set(Self.reference.map(\.name))

        XCTAssertTrue(expected.subtracting(declared).isEmpty,
                      """
                      missing: \(expected.subtracting(declared).sorted()). Running only outbound \
                      processing is not a partial implementation of this loop — it is a node that \
                      accepts peerings, answers announces and never propagates anything.
                      """)
    }

    func testEveryRoutineTheReferenceDoesNotHaveSaysWhyItIsHere() {
        let expected = Set(Self.reference.map(\.name))
        let additions = LXMRouter.jobSchedule.filter { !expected.contains($0.name) }

        for job in additions {
            XCTAssertNotNil(job.additionReason,
                            """
                            \(job.name) is in this port's schedule and not in the reference's \
                            (LXMRouter.py:880-911), with no reason recorded. A divergence with a \
                            recorded reason is a decision; one without is a mistake nobody has \
                            noticed yet — which is exactly how the three-of-ten loop survived.
                            """)
            XCTAssertFalse(job.additionReason?.isEmpty ?? true,
                           "\(job.name) declares an empty reason for diverging")
        }
    }

    func testEveryRoutineRunsOnTheReferenceInterval() {
        for entry in Self.reference {
            guard let job = LXMRouter.jobSchedule.first(where: { $0.name == entry.name }) else {
                continue    // reported by testTheScheduleNamesEveryReferenceRoutine
            }
            XCTAssertEqual(job.interval, entry.interval,
                           """
                           \(entry.name) is scheduled every \(job.interval) ticks; the reference \
                           runs it every \(entry.interval). An interval that is merely present is \
                           not the same as one that matches — too short dials peers more often \
                           than the reference, too long stalls propagation.
                           """)
        }
    }

    func testEveryRoutineIsGatedAsTheReferenceGatesIt() {
        for entry in Self.reference {
            guard let job = LXMRouter.jobSchedule.first(where: { $0.name == entry.name }) else {
                continue
            }
            XCTAssertEqual(job.propagationNodeOnly, entry.propagationNodeOnly,
                           """
                           \(entry.name): propagationNodeOnly is \(job.propagationNodeOnly), the \
                           reference has \(entry.propagationNodeOnly). `clean_throttled_peers` in \
                           particular sits inside the peer-sync block but *outside* its \
                           propagation-node guard (LXMRouter.py:908-910).
                           """)
        }
    }

    // MARK: - Dispatch

    func testARoutineRunsOnlyOnItsOwnTicks() throws {
        let router = try makePropagationNode()
        var ranOn: [String: [Int]] = [:]

        for tick in 1...12 {
            for name in router.jobs() { ranOn[name, default: []].append(tick) }
        }

        for entry in Self.reference where entry.interval <= 12 {
            // A routine the port has not written is scheduled but not dispatched, and says why
            // (`testEveryScheduledRoutineHasABodyOrARecordedReason`). Asserting it ran would
            // require a body that does nothing, which is the shape that hides a missing routine.
            guard LXMRouter.jobSchedule.first(where: { $0.name == entry.name })?.pendingReason == nil
            else {
                XCTAssertNil(ranOn[entry.name],
                             "\(entry.name) is recorded as unimplemented and ran anyway")
                continue
            }
            let expected = Array(stride(from: entry.interval, through: 12, by: entry.interval))
            XCTAssertEqual(ranOn[entry.name] ?? [], expected,
                           """
                           \(entry.name) ran on ticks \(ranOn[entry.name] ?? []) over 12; every \
                           \(entry.interval) ticks means \(expected). Declaring an interval and \
                           dispatching on it are separate things.
                           """)
        }
    }

    func testARoutineWithATallIntervalDoesNotRunEarly() throws {
        let router = try makePropagationNode()
        var ran: Set<String> = []
        for _ in 1...59 { ran.formUnion(router.jobs()) }

        XCTAssertFalse(ran.contains("cleanTransientIDCaches"),
                       "the transient-ID sweep ran inside 60 ticks")
        XCTAssertFalse(ran.contains("rotatePeers"),
                       "peer rotation ran inside its 336-tick interval — rotation judges peers on "
                       + "their acceptance record, and running it early judges them on less of one")
    }

    func testPropagationOnlyRoutinesDoNotRunOnAPlainClient() {
        let client = LXMRouter(transport: Transport())     // never enablePropagation
        var ran: Set<String> = []
        for _ in 1...336 { ran.formUnion(client.jobs()) }

        for entry in Self.reference where entry.propagationNodeOnly {
            XCTAssertFalse(ran.contains(entry.name),
                           "\(entry.name) is propagation-node-only and ran on a plain client")
        }
        XCTAssertTrue(ran.contains("cleanThrottledPeers"),
                      """
                      cleanThrottledPeers must run on a plain client too — the reference puts it \
                      inside the peer-sync interval but outside the propagation-node guard \
                      (LXMRouter.py:908-910), and a test that only checked the gated routines \
                      would not notice it being gated by mistake.
                      """)
    }

    // MARK: - Bodies

    /// `jobs()` returns the names of the routines it dispatched, and every other test in this file
    /// reads that return value — so all of them would stay green if a routine's *body* were
    /// emptied. The name is reported by the schedule, not by the work.
    ///
    /// This one asserts an observable effect instead: `cleanThrottledPeers` is the cheapest
    /// routine to set up state for and is dispatched on a plain client, so it needs no propagation
    /// node. Deleting its body fails here and nowhere else.
    func testARoutinesBodyActuallyRuns() throws {
        let router = try makePropagationNode()
        router.seedThrottledPeer(Data(repeating: 0x11, count: 16), until: Date().timeIntervalSince1970 - 1)
        XCTAssertEqual(router.throttledPeers.count, 1, "precondition: there is an expired entry")

        // cleanThrottledPeers runs every jobPeerSyncInterval ticks.
        for _ in 1...LXMRouter.jobPeerSyncInterval { _ = router.jobs() }

        XCTAssertTrue(router.throttledPeers.isEmpty,
                      """
                      the loop reported running cleanThrottledPeers and the expired entry is still \
                      there. A schedule that names a routine and dispatches an empty body is \
                      indistinguishable, to every other test here, from one that works.
                      """)
    }

    func testEveryScheduledRoutineHasABodyOrARecordedReason() {
        let pending = LXMRouter.jobSchedule.filter { $0.pendingReason != nil }
        for job in pending {
            XCTAssertFalse(job.pendingReason!.isEmpty,
                           "\(job.name) is scheduled but unimplemented with an empty reason")
        }
        // Not an assertion that `pending` is empty: a routine the port has not written yet is
        // recorded here rather than omitted from the schedule, because an omitted routine is
        // indistinguishable from one nobody noticed — which is how `bugs/019` survived.
        XCTAssertTrue(pending.allSatisfy { Self.reference.map(\.name).contains($0.name) },
                      "a pending routine that is not in the reference schedule at all")
    }

    // MARK: - Harness

    private var retained: [Transport] = []

    private func makePropagationNode() throws -> LXMRouter {
        let transport = Transport()
        retained.append(transport)
        let router = LXMRouter(transport: transport)
        try router.register(identity: Identity(), transport: transport)
        try router.enablePropagation(storagePath: tempDir)
        return router
    }
}
