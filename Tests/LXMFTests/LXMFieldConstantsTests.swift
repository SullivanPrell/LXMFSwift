import XCTest
@testable import LXMF

/// Verify that the Swift `Field` enum raw values match the Python LXMF constants exactly.
final class LXMFieldConstantsTests: XCTestCase {
    func testEmbeddedLXMs()       { XCTAssertEqual(Field.embeddedLXMs.rawValue,    0x01) }
    func testTelemetry()          { XCTAssertEqual(Field.telemetry.rawValue,        0x02) }
    func testTelemetryStream()    { XCTAssertEqual(Field.telemetryStream.rawValue,  0x03) }
    func testIconAppearance()     { XCTAssertEqual(Field.iconAppearance.rawValue,   0x04) }
    func testFileAttachments()    { XCTAssertEqual(Field.fileAttachments.rawValue,  0x05) }
    func testImage()              { XCTAssertEqual(Field.image.rawValue,            0x06) }
    func testAudio()              { XCTAssertEqual(Field.audio.rawValue,            0x07) }
    func testThread()             { XCTAssertEqual(Field.thread.rawValue,           0x08) }
    func testCommands()           { XCTAssertEqual(Field.commands.rawValue,         0x09) }
    func testResults()            { XCTAssertEqual(Field.results.rawValue,          0x0A) }
    func testGroup()              { XCTAssertEqual(Field.group.rawValue,            0x0B) }
    func testTicket()             { XCTAssertEqual(Field.ticket.rawValue,           0x0C) }
    func testEvent()              { XCTAssertEqual(Field.event.rawValue,            0x0D) }
    func testRnrRefs()            { XCTAssertEqual(Field.rnrRefs.rawValue,          0x0E) }
    func testRenderer()           { XCTAssertEqual(Field.renderer.rawValue,         0x0F) }
    func testCustomType()         { XCTAssertEqual(Field.customType.rawValue,       0xFB) }
    func testCustomData()         { XCTAssertEqual(Field.customData.rawValue,       0xFC) }
    func testCustomMeta()         { XCTAssertEqual(Field.customMeta.rawValue,       0xFD) }
    func testNonSpecific()        { XCTAssertEqual(Field.nonSpecific.rawValue,      0xFE) }
    func testDebug()              { XCTAssertEqual(Field.debug.rawValue,            0xFF) }
}
