import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/048` — a propagation node's advertised costs default to the reference's values.
///
/// Python defaults `peering_cost` to `PEERING_COST = 18`, `propagation_stamp_cost` to
/// `PROPAGATION_COST = 16` with a `PROPAGATION_COST_MIN = 13` floor applied in `__init__`
/// (`LXMRouter.py:50-54, 97-103, 136`), and the flexibility to `PROPAGATION_COST_FLEX = 3`. This
/// port hardcoded all three to `0`.
///
/// A zero peering cost is not "no proof of work required" on the Python side — it is a value that
/// can never be satisfied:
///
/// ```python
/// # LXMF/LXMPeer.py:227-228
/// def peering_key_ready(self):
///     if not self.peering_cost: return False
/// ```
///
/// So a default-configured node built on this port advertises a cost every Python peer treats as
/// permanently unmeetable. The peering succeeds, the peer sits in the table, and every sync pass
/// postpones — silently, forever. Nothing on either side reports an error.
///
/// The three constants that *were* ported all have `default…` statics behind them
/// (`defaultAutopeer`, `defaultMaxPeers`, `defaultMaxPeeringCost`); the three that were not are
/// exactly the three declared as plain `= 0`. This file asserts the values and the floor, and
/// `testTheAdvertisedCostsAreWhatAPeerReads` asserts they reach the wire, because a default that
/// the announce builder does not read would be the same defect one layer along.
final class PeeringCostDefaultsTests: XCTestCase {

    private var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_costs_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        retained.removeAll()
        super.tearDown()
    }

    // MARK: - The constants

    func testTheReferenceCostConstantsArePresent() {
        XCTAssertEqual(LXMRouter.defaultPeeringCost, 18, "Python PEERING_COST (LXMRouter.py:50)")
        XCTAssertEqual(LXMRouter.defaultPropagationStampCost, 16,
                       "Python PROPAGATION_COST (LXMRouter.py:54)")
        XCTAssertEqual(LXMRouter.defaultPropagationStampCostFlexibility, 3,
                       "Python PROPAGATION_COST_FLEX (LXMRouter.py:53)")
        XCTAssertEqual(LXMRouter.propagationStampCostMin, 13,
                       "Python PROPAGATION_COST_MIN (LXMRouter.py:52)")
    }

    // MARK: - The defect

    func testANewRouterDoesNotAdvertiseAZeroPeeringCost() {
        let router = LXMRouter(transport: Transport())
        retained.append(router)

        XCTAssertNotEqual(router.peeringCost, 0,
                          """
                          a peering cost of 0 is not "no proof of work required" — Python's \
                          `peering_key_ready` opens with `if not self.peering_cost: return False` \
                          (LXMPeer.py:228), so a peer advertising 0 can never be synced to. The \
                          peering succeeds and then every sync pass postpones, forever, with no \
                          error on either side.
                          """)
        XCTAssertEqual(router.peeringCost, LXMRouter.defaultPeeringCost)
    }

    func testANewRouterDemandsTheReferenceStampCost() {
        let router = LXMRouter(transport: Transport())
        retained.append(router)

        XCTAssertEqual(router.propagationStampCost, LXMRouter.defaultPropagationStampCost,
                       """
                       a node demanding a stamp cost of 0 accepts every message anyone sends it, \
                       which is the entire spam control the propagation network has.
                       """)
        XCTAssertEqual(router.propagationStampCostFlexibility,
                       LXMRouter.defaultPropagationStampCostFlexibility)
    }

    // MARK: - The floor

    func testAStampCostBelowTheMinimumIsRaisedToIt() {
        // Through the initialiser, which is where the reference clamps (`LXMRouter.py:136`).
        let router = LXMRouter(transport: Transport(), propagationStampCost: 4)
        retained.append(router)

        XCTAssertEqual(router.propagationStampCost, LXMRouter.propagationStampCostMin,
                       """
                       Python clamps in `__init__`: `if propagation_cost < PROPAGATION_COST_MIN: \
                       propagation_cost = PROPAGATION_COST_MIN` (LXMRouter.py:136). Without the \
                       floor an operator can configure a node that is cheaper to flood than the \
                       network assumes any node is.
                       """)
    }

    func testAStampCostAtOrAboveTheMinimumIsKept() {
        let router = LXMRouter(transport: Transport(), propagationStampCost: 20)
        retained.append(router)

        XCTAssertEqual(router.propagationStampCost, 20,
                       "the floor must raise only what is below it, not pin every value to it")

        // Python clamps the constructor argument and leaves the attribute alone, so a caller that
        // assigns directly is not clamped. Asserted so the two paths cannot silently converge.
        let direct = LXMRouter(transport: Transport())
        retained.append(direct)
        direct.propagationStampCost = 4
        XCTAssertEqual(direct.propagationStampCost, 4,
                       "direct assignment is unclamped in the reference (LXMRouter.py:136 vs :147)")
    }

    // MARK: - The wire

    func testTheAdvertisedCostsAreWhatAPeerReads() throws {
        let transport = Transport()
        let router = LXMRouter(transport: transport)
        retained.append(transport); retained.append(router)
        try router.register(identity: Identity(), transport: transport)
        try router.enablePropagation(storagePath: tempDir)

        // Field 5 of the announce is `[stamp_cost, flexibility, peering_cost]`
        // (`LXMRouter.py:327`) — decoded here exactly as a remote peer decodes it.
        let announce = try XCTUnwrap(PropagationNodeAnnounce(appData: router.getPropagationNodeAppData()),
                                     "the node's own announce data must decode as a peer reads it")

        XCTAssertEqual(announce.peeringCost, LXMRouter.defaultPeeringCost,
                       "the peering cost a remote reads is the one that gates its sync to us")
        XCTAssertEqual(announce.stampCost, LXMRouter.defaultPropagationStampCost)
        XCTAssertEqual(announce.stampCostFlexibility,
                       LXMRouter.defaultPropagationStampCostFlexibility)
    }

    private var retained: [AnyObject] = []
}
