import XCTest
import ReticulumSwift
@testable import LXMF

/// Parity tests for LXMF 1.1.0 inbound message-resource tracking
/// (Python commit d909619) and the `propagation_transfer_size` field.
final class InboundResourceTrackingTests: XCTestCase {

    private func makeRouter() -> LXMRouter {
        LXMRouter(transport: Transport())
    }

    // MARK: - Registry lifecycle

    func testInboundCountStartsAtZero() {
        XCTAssertEqual(makeRouter().inboundCount(), 0)
        XCTAssertTrue(makeRouter().inboundResources().isEmpty)
    }

    func testCancelUnknownResourceReturnsFalse() {
        let router = makeRouter()
        XCTAssertFalse(router.cancelInbound(resourceHash: Data(repeating: 0xAB, count: 32)),
                       "Python logs a warning and returns False for an unknown resource hash")
    }

    func testCancelAllInboundWithNothingRunningReturnsZero() {
        XCTAssertEqual(makeRouter().cancelAllInbound(), 0)
    }

    func testJobResourceIntervalMatchesPython() {
        XCTAssertEqual(LXMRouter.jobResourceInterval, 2,
                       "Python LXMRouter.JOB_RESOURCE_INTERVAL = 2")
    }

    /// The reap must not disturb an empty registry, and must be safe to call
    /// repeatedly (the job loop calls it every other tick forever).
    func testCleanResourceTrackingIsIdempotent() {
        let router = makeRouter()
        router.cleanResourceTracking()
        router.cleanResourceTracking()
        XCTAssertEqual(router.inboundCount(), 0)
    }

    // MARK: - propagation_transfer_size

    func testPropagationTransferSizeStartsNil() {
        XCTAssertNil(makeRouter().propagationTransferSize,
                     "Python: self.propagation_transfer_size = None")
    }

    func testCancelPropagationRequestsClearsTransferSize() {
        let router = makeRouter()
        router.propagationTransferSize = 4096
        router.cancelPropagationNodeRequests()
        XCTAssertNil(router.propagationTransferSize,
                     "a cancelled sync must not leave a stale byte count for the UI to render")
    }
}
