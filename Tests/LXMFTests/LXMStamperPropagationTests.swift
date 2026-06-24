import XCTest
@testable import LXMF
import ReticulumSwift

/// Tests for LXStamper propagation-node stamp validation and peering key validation.
final class LXMStamperPropagationTests: XCTestCase {

    // MARK: - Constants

    func testPNStampExpandRounds() {
        XCTAssertEqual(LXStamper.pnStampExpandRounds, 1000)
    }

    func testPeeringExpandRounds() {
        XCTAssertEqual(LXStamper.peeringExpandRounds, 25)
    }

    func testStampSize() {
        XCTAssertEqual(LXStamper.stampSize, 32)
    }

    // MARK: - validatePNStamp

    func testValidatePNStampRejectsShortData() {
        // Too short (≤ lxmfOverhead + stampSize)
        let shortData = Data(repeating: 0xFF, count: 10)
        let result = LXStamper.validatePNStamp(transientData: shortData, targetCost: 0)
        XCTAssertNil(result, "Should reject data shorter than LXMF overhead + stamp size")
    }

    func testValidatePNStampRejectsInvalidStamp() {
        // Build data that is long enough but has a stamp that won't satisfy even cost=1
        let overhead = LXMessage.lxmfOverhead + LXStamper.stampSize + 10
        let data     = Data(repeating: 0x01, count: overhead)
        // Cost of 1 with expand 1000 rounds — extremely unlikely to pass by accident.
        // In fact impossible with all-zeros stamp unless we specifically craft one.
        // We set cost=1 to test the rejection path with obviously-invalid stamp bytes.
        // NOTE: This test only verifies the API doesn't crash; the validation outcome
        // depends on the actual PoW check which is slow. We use cost=200 to guarantee rejection.
        let result = LXStamper.validatePNStamp(transientData: data, targetCost: 200)
        XCTAssertNil(result, "Should reject invalid stamp (cost 200)")
    }

    func testValidatePNStampReturnsNilForCostZeroOnBadData() {
        // Even cost=0 (accept anything) should fail if data is too short.
        let shortData = Data(repeating: 0x00, count: LXMessage.lxmfOverhead)
        let result    = LXStamper.validatePNStamp(transientData: shortData, targetCost: 0)
        XCTAssertNil(result)
    }

    func testValidatePNStampAcceptsCostZero() {
        // With cost=0, any stamp (all zeros) should pass since 0 leading bits is trivially satisfied.
        // Data must be longer than lxmfOverhead + stampSize.
        let dataSize  = LXMessage.lxmfOverhead + LXStamper.stampSize + 1
        let lxmfBytes = Data(repeating: 0x11, count: dataSize - LXStamper.stampSize)
        let stamp     = Data(count: LXStamper.stampSize)  // all-zero stamp
        let combined  = lxmfBytes + stamp

        let result = LXStamper.validatePNStamp(transientData: combined, targetCost: 0)
        XCTAssertNotNil(result, "Cost=0 should accept any stamp")
        XCTAssertEqual(result?.lxmfData, lxmfBytes)
        XCTAssertEqual(result?.stamp,    stamp)
    }

    func testValidatePNStampReturnsTuple() {
        // Use cost=0 to guarantee acceptance.
        let lxmfBytes = Data(repeating: 0x22, count: LXMessage.lxmfOverhead + 10)
        let stamp     = Data(count: LXStamper.stampSize)
        let combined  = lxmfBytes + stamp

        if let result = LXStamper.validatePNStamp(transientData: combined, targetCost: 0) {
            XCTAssertEqual(result.lxmfData, lxmfBytes)
            XCTAssertEqual(result.stamp,    stamp)
            XCTAssertGreaterThanOrEqual(result.stampValue, 0)
            // transientID = fullHash(lxmfBytes)
            XCTAssertEqual(result.transientID, Hashes.fullHash(lxmfBytes))
        } else {
            XCTFail("Expected non-nil result for cost=0")
        }
    }

    // MARK: - validatePNStamps (batch)

    func testValidatePNStampsReturnsValidOnly() {
        let lxmfBytes = Data(repeating: 0x33, count: LXMessage.lxmfOverhead + 10)
        let stamp     = Data(count: LXStamper.stampSize)
        let validEntry = lxmfBytes + stamp

        // Short entry = always invalid
        let invalidEntry = Data(repeating: 0xFF, count: 5)

        let results = LXStamper.validatePNStamps(
            transientList: [validEntry, invalidEntry], targetCost: 0)
        XCTAssertEqual(results.count, 1, "Only valid entry should be returned")
    }

    func testValidatePNStampsEmptyList() {
        let results = LXStamper.validatePNStamps(transientList: [], targetCost: 0)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - validatePeeringKey

    func testValidatePeeringKeyRejectsInvalid() {
        let peeringID  = Data(repeating: 0x01, count: 32)
        let peeringKey = Data(repeating: 0xFF, count: 32)
        // Cost=200 → impossible to satisfy with random bytes
        let result = LXStamper.validatePeeringKey(
            peeringID: peeringID, peeringKey: peeringKey, targetCost: 200)
        XCTAssertFalse(result, "Should reject invalid peering key with high cost")
    }

    func testValidatePeeringKeyAcceptsCostZero() {
        // Cost=0 — any stamp passes.
        let peeringID  = Data(repeating: 0x01, count: 32)
        let peeringKey = Data(count: 32)
        let result = LXStamper.validatePeeringKey(
            peeringID: peeringID, peeringKey: peeringKey, targetCost: 0)
        XCTAssertTrue(result, "Cost=0 must always pass")
    }
}
