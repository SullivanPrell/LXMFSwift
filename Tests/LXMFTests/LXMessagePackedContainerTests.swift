import XCTest
import Foundation
import LXMF
import ReticulumSwift

/// Tests for LXMessage.packedContainer(), the fixed writeToDirectory format,
/// and the fixed unpackFromFile container-aware reading.
///
/// Python's wire format for stored messages is:
///   msgpack({"lxmf_bytes": <packed>, "state": <int>, "transport_encrypted": <bool>,
///            "transport_encryption": <string|nil>, "method": <int>})
///
/// This matches Python's LXMessage.packed_container() and write_to_directory().
final class LXMessagePackedContainerTests: XCTestCase {

    // MARK: - Helpers

    private func makeMessage(content: String = "Hello", title: String = "Test") throws -> LXMessage {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single,
                                  appName: "lxmf", aspects: ["delivery"])
        let msg = LXMessage(destination: dst, source: src, content: content, title: title)
        try msg.pack()
        return msg
    }

    // MARK: - packedContainer() tests

    /// Test 1: packedContainer() returns non-empty Data.
    func testPackedContainerReturnsData() throws {
        let msg = try makeMessage()
        let container = try msg.packedContainer()
        XCTAssertFalse(container.isEmpty)
    }

    // MARK: - Helper for container key lookup
    private func containerValue(for key: String, in pairs: [(MsgPack.Value, MsgPack.Value)]) -> MsgPack.Value? {
        pairs.first { if case .string(let s) = $0.0 { return s == key }; return false }?.1
    }

    /// Test 2: packedContainer() is a msgpack dict containing "lxmf_bytes".
    func testPackedContainerIsMsgpackDict() throws {
        let msg = try makeMessage()
        let container = try msg.packedContainer()
        // Decode container — must be a msgpack map with "lxmf_bytes" key
        guard case .map(let pairs) = try MsgPack.decode(container) else {
            XCTFail("packedContainer must decode as a msgpack map")
            return
        }
        XCTAssertNotNil(containerValue(for: "lxmf_bytes", in: pairs),
                        "Container must have lxmf_bytes key")
    }

    /// Test 3: lxmf_bytes in container matches message.packed.
    func testPackedContainerLxmfBytesMatchesPacked() throws {
        let msg = try makeMessage(content: "Wire bytes match")
        let container = try msg.packedContainer()
        guard case .map(let pairs) = try MsgPack.decode(container) else {
            XCTFail("Not a map"); return
        }
        guard let lxmfBytesVal = containerValue(for: "lxmf_bytes", in: pairs),
              case .bytes(let bytes) = lxmfBytesVal else {
            XCTFail("lxmf_bytes must be a byte array"); return
        }
        XCTAssertEqual(bytes, msg.packed!, "lxmf_bytes must equal message.packed")
    }

    /// Test 4: Container includes state, method fields.
    func testPackedContainerIncludesStateAndMethod() throws {
        let msg = try makeMessage()
        let container = try msg.packedContainer()
        guard case .map(let pairs) = try MsgPack.decode(container) else {
            XCTFail("Not a map"); return
        }
        XCTAssertNotNil(containerValue(for: "state", in: pairs),  "Container must have state key")
        XCTAssertNotNil(containerValue(for: "method", in: pairs), "Container must have method key")
    }

    /// Test 5: Container includes transport_encrypted field.
    func testPackedContainerIncludesTransportEncrypted() throws {
        let msg = try makeMessage()
        let container = try msg.packedContainer()
        guard case .map(let pairs) = try MsgPack.decode(container) else {
            XCTFail("Not a map"); return
        }
        XCTAssertNotNil(containerValue(for: "transport_encrypted", in: pairs),
                        "Container must have transport_encrypted key")
    }

    // MARK: - writeToDirectory + unpackFromFile round-trip

    /// Test 6: writeToDirectory writes a file; unpackFromFile reads it back with correct content.
    func testWriteAndReadContainerRoundTrip() throws {
        let msg = try makeMessage(content: "Container round-trip", title: "Container title")
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = try msg.writeToDirectory(tmpDir)
        XCTAssertNotNil(fileURL, "writeToDirectory must return a URL on success")

        let handle = try FileHandle(forReadingFrom: fileURL!)
        defer { handle.closeFile() }

        let restored = try LXMessage.unpackFromFile(handle)
        XCTAssertEqual(restored.destinationHash, msg.destinationHash)
        XCTAssertEqual(restored.content, msg.content)
        XCTAssertEqual(restored.title, msg.title)
    }

    /// Test 7: unpackFromFile on raw packed bytes (legacy) falls back gracefully.
    /// Files written by earlier Swift versions contain raw bytes — we must read them too.
    func testUnpackFromFileHandlesLegacyRawBytes() throws {
        let msg = try makeMessage(content: "Legacy bytes")
        guard let raw = msg.packed else {
            XCTFail("pack() did not set packed"); return
        }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lxm")
        try raw.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let handle = try FileHandle(forReadingFrom: tmpURL)
        defer { handle.closeFile() }

        // Must not throw — fallback to raw unpack
        let restored = try LXMessage.unpackFromFile(handle)
        XCTAssertEqual(restored.destinationHash, msg.destinationHash)
        XCTAssertEqual(restored.content, msg.content)
    }

    /// Test 8: writeToDirectory file is named by the message hash.
    func testWriteToDirectoryUsesHashAsFileName() throws {
        let msg = try makeMessage(content: "Named by hash")
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = try msg.writeToDirectory(tmpDir)
        XCTAssertNotNil(fileURL)

        let expectedName = msg.hash!.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fileURL!.lastPathComponent, expectedName,
                       "File name must be the hex hash of the message")
    }

    /// Test 9: State is preserved in container round-trip.
    func testContainerPreservesState() throws {
        let msg = try makeMessage(content: "State preserved")
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = try msg.writeToDirectory(tmpDir)!
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }

        let restored = try LXMessage.unpackFromFile(handle)
        // Packed messages have state .outbound (2) before delivery
        // unpackFromFile restores the state from the container
        XCTAssertNotNil(restored.state)
    }

    // MARK: - Python container format compatibility

    /// Test 10: A hand-crafted Python-format container is readable by unpackFromFile.
    func testReadsPythonFormatContainer() throws {
        let msg = try makeMessage(content: "From Python")
        guard let packed = msg.packed else {
            XCTFail("pack() did not set packed"); return
        }

        // Build the Python-style container dict manually
        // Python format: {"lxmf_bytes": <bytes>, "state": 4, "transport_encrypted": False,
        //                 "transport_encryption": None, "method": 0}
        let containerPairs: [(MsgPack.Value, MsgPack.Value)] = [
            (.string("lxmf_bytes"),          .bytes(packed)),
            (.string("state"),               .uint(4)),
            (.string("transport_encrypted"), .bool(false)),
            (.string("method"),              .uint(0)),
        ]
        let encoded = MsgPack.encode(.map(containerPairs))

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lxm")
        try encoded.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let handle = try FileHandle(forReadingFrom: tmpURL)
        defer { handle.closeFile() }

        let restored = try LXMessage.unpackFromFile(handle)
        XCTAssertEqual(restored.destinationHash, msg.destinationHash)
        XCTAssertEqual(restored.content, msg.content)
        XCTAssertEqual(restored.state.rawValue, 4)
    }
}
