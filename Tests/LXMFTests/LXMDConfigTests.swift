import XCTest
@testable import LXMF

/// Tests for LXMDConfig — lxmd daemon constants and example configuration.
/// Python reference: LXMF/Utilities/lxmd.py

final class LXMDConfigTests: XCTestCase {

    // MARK: - Timing constants

    func testDeferredJobsDelay() {
        // Python: DEFFERED_JOBS_DELAY = 10
        XCTAssertEqual(LXMDConfig.deferredJobsDelay, 10)
    }

    func testJobsInterval() {
        // Python: JOBS_INTERVAL = 5
        XCTAssertEqual(LXMDConfig.jobsInterval, 5)
    }

    // MARK: - Example config

    func testExampleConfigNotEmpty() {
        XCTAssertFalse(LXMDConfig.exampleConfig.isEmpty)
    }

    func testExampleConfigContainsPropagationSection() {
        XCTAssertTrue(LXMDConfig.exampleConfig.contains("[propagation]"))
    }

    func testExampleConfigContainsLXMFSection() {
        XCTAssertTrue(LXMDConfig.exampleConfig.contains("[lxmf]"))
    }

    func testExampleConfigContainsLoggingSection() {
        XCTAssertTrue(LXMDConfig.exampleConfig.contains("[logging]"))
    }

    func testExampleConfigEnableNodeDefault() {
        // Python default: enable_node = no
        XCTAssertTrue(LXMDConfig.exampleConfig.contains("enable_node = no"))
    }

    func testExampleConfigAuthRequiredDefault() {
        // Python default: auth_required = no
        XCTAssertTrue(LXMDConfig.exampleConfig.contains("auth_required = no"))
    }

    func testExampleConfigAnnounceInterval() {
        // Python default: announce_interval = 360  (6 hours)
        XCTAssertTrue(LXMDConfig.exampleConfig.contains("announce_interval = 360"))
    }

    func testExampleConfigDisplayName() {
        // Python default: display_name = Anonymous Peer
        XCTAssertTrue(LXMDConfig.exampleConfig.contains("display_name = Anonymous Peer"))
    }
}
