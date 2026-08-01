import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/054` — a propagation node pushes its store to its peers.
///
/// Every assertion here is about **B's message store**, not A's state machine. The defect these
/// replace was a machine that set `state = .linkEstablishing` and stopped; asserting A's state
/// cannot distinguish that from a working sync.
final class PeerOutboundSyncTests: XCTestCase {

    private var tempDir: String!
    private var net: PeerOutboundSyncNetwork!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "lxmf_outsync_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        net = nil
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - The harness itself

    /// Not a test of the port — a test that the fixture below it means anything. If A never peers
    /// with B, every sync assertion in this file passes or fails for reasons unrelated to sync.
    func testTheHarnessPeersAWithBOverTheWire() throws {
        net = try PeerOutboundSyncNetwork(test: self, tempDir: tempDir, peeringCost: 4)
        let peer = try net.announceBToA()

        XCTAssertEqual(peer.destinationHash, net.bPropagationHash)
        XCTAssertEqual(peer.peeringCost, 4,
                       "the announce must carry B's peering cost — without it A never builds a key")
        XCTAssertNotNil(peer.propagationStampCost, "and its stamp costs, or sync postpones forever")
        XCTAssertTrue(net.transportA.hasPath(to: net.bPropagationHash),
                      "the announce must also leave A with a path to dial")
        XCTAssertNotNil(net.transportA.recall(identity: net.bPropagationHash),
                        "and B's identity, or no peering material can be computed")
    }
}
