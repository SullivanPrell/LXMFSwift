import XCTest
import ReticulumSwift
@testable import LXMF

/// Tests for LXMessage convenience setters/getters and writeToDirectory().
///
/// Python reference (LXMessage.py):
///   message.set_title_from_string(str)
///   message.set_content_from_string(str)
///   message.set_fields(dict)
///   message.get_fields()
///   message.write_to_directory(path) → file path string | None
final class LXMessageConvenienceTests: XCTestCase {

    private func makeSrcDst() throws -> (Destination, Destination) {
        let srcID = Identity(); let dstID = Identity()
        let src = try Destination(identity: srcID, direction: .in, kind: .single, appName: APP_NAME, aspects: ["delivery"])
        let dst = try Destination(identity: dstID, direction: .in, kind: .single, appName: APP_NAME, aspects: ["delivery"])
        return (src, dst)
    }

    // MARK: - set_title_from_string

    func testSetTitleFromString() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src, content: "")
        msg.setTitleFromString("Hello World")
        XCTAssertEqual(msg.titleAsString, "Hello World",
                       "setTitleFromString must update titleAsString")
    }

    func testSetTitleFromStringUTF8() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src, content: "")
        let utf8Title = "Héllo Wörld 🌍"
        msg.setTitleFromString(utf8Title)
        XCTAssertEqual(msg.titleAsString, utf8Title)
    }

    func testSetTitleFromBytes() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src, content: "")
        let bytes = Data("bytes title".utf8)
        msg.setTitleFromBytes(bytes)
        XCTAssertEqual(msg.title, bytes)
    }

    // MARK: - set_content_from_string

    func testSetContentFromString() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src, content: "")
        msg.setContentFromString("new content")
        XCTAssertEqual(msg.contentAsString, "new content")
    }

    func testSetContentFromBytes() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src, content: "")
        let bytes = Data([0x01, 0x02, 0x03])
        msg.setContentFromBytes(bytes)
        XCTAssertEqual(msg.content, bytes)
    }

    // MARK: - set_fields / get_fields

    func testSetFieldsAndGetFields() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src, content: "")
        let newFields: [Int: Any] = [1: "value1", 2: 42]
        msg.setFields(newFields)
        let retrieved = msg.getFields()
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?[1] as? String, "value1")
        XCTAssertEqual(retrieved?[2] as? Int, 42)
    }

    func testSetFieldsNilClearsFields() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src, content: "")
        msg.setFields([1: "val"])
        msg.setFields(nil)
        XCTAssertTrue(msg.getFields()?.isEmpty ?? true,
                      "setFields(nil) must clear the fields dict")
    }

    func testGetFieldsDefaultEmpty() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src, content: "")
        let fields = msg.getFields()
        XCTAssertNotNil(fields, "getFields() must not return nil by default")
        XCTAssertTrue(fields!.isEmpty, "default fields must be empty")
    }

    // MARK: - write_to_directory

    func testWriteToDirectoryCreatesFile() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src, content: "write me")
        try msg.pack()

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LXMWriteTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = try msg.writeToDirectory(tmpDir)
        XCTAssertNotNil(path, "writeToDirectory must return a path on success")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path!.path),
                      "file must exist at the returned path")
    }

    func testWriteToDirectoryFileNameIsHexHash() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src, content: "hashname")
        try msg.pack()
        guard let hash = msg.hash else { XCTFail("hash must be set"); return }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LXMWriteTest2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = try msg.writeToDirectory(tmpDir)
        let expectedName = hash.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(path?.lastPathComponent, expectedName,
                       "written file must be named by the message hash (hex, no delimiters)")
    }
}
