import XCTest
import Foundation
import LXMF
import ReticulumSwift

/// Tests for LXMessage.unpackFromFile(_:) and LXMessage.determineCompressionSupport().
final class LXMessageFileTests: XCTestCase {

    // MARK: - Helpers

    private func makeMessage(content: String = "Hello", title: String = "Title") throws -> LXMessage {
        let srcIdentity = Identity()
        let dstIdentity = Identity()
        let src = try Destination(identity: srcIdentity, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let dst = try Destination(identity: dstIdentity, direction: .in, kind: .single, appName: "lxmf", aspects: ["delivery"])
        let msg = LXMessage(destination: dst, source: src, content: content, title: title)
        try msg.pack()
        return msg
    }

    private func tempFileHandle(data: Data) throws -> (FileHandle, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lxm")
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        return (handle, url)
    }

    // MARK: - unpackFromFile tests

    /// Test 1: Round-trip — pack then unpackFromFile restores destinationHash and content.
    func testUnpackFromFileRoundTrip() throws {
        let original = try makeMessage(content: "Round-trip content", title: "Round-trip title")
        guard let packedData = original.packed else {
            XCTFail("pack() did not set packed")
            return
        }

        let (handle, url) = try tempFileHandle(data: packedData)
        defer {
            handle.closeFile()
            try? FileManager.default.removeItem(at: url)
        }

        let restored = try LXMessage.unpackFromFile(handle)

        XCTAssertEqual(restored.destinationHash, original.destinationHash,
                       "destinationHash must survive round-trip")
        XCTAssertEqual(restored.content, original.content,
                       "content must survive round-trip")
        XCTAssertEqual(restored.contentAsString, "Round-trip content",
                       "contentAsString must survive round-trip")
        XCTAssertEqual(restored.title, original.title,
                       "title must survive round-trip")
    }

    /// Test 2: Missing / empty data throws an error.
    func testUnpackFromFileEmptyDataThrows() throws {
        let (handle, url) = try tempFileHandle(data: Data())
        defer {
            handle.closeFile()
            try? FileManager.default.removeItem(at: url)
        }

        XCTAssertThrowsError(try LXMessage.unpackFromFile(handle),
                             "Empty data must throw") { error in
            // Any LXMessageError is acceptable
            XCTAssertNotNil(error as? LXMessage.LXMessageError)
        }
    }

    /// Test 3: Malformed (truncated) data throws an error.
    func testUnpackFromFileMalformedDataThrows() throws {
        // Too short to be a valid LXMF message
        let junk = Data(repeating: 0xAB, count: 10)
        let (handle, url) = try tempFileHandle(data: junk)
        defer {
            handle.closeFile()
            try? FileManager.default.removeItem(at: url)
        }

        XCTAssertThrowsError(try LXMessage.unpackFromFile(handle),
                             "Truncated data must throw") { error in
            XCTAssertNotNil(error as? LXMessage.LXMessageError)
        }
    }

    /// Test 4: State field is restored — incoming flag is set after unpackFromFile.
    func testUnpackFromFileSetsIncomingFlag() throws {
        let original = try makeMessage(content: "State test")
        guard let packedData = original.packed else {
            XCTFail("pack() did not set packed")
            return
        }

        let (handle, url) = try tempFileHandle(data: packedData)
        defer {
            handle.closeFile()
            try? FileManager.default.removeItem(at: url)
        }

        let restored = try LXMessage.unpackFromFile(handle)
        // unpack sets incoming = true (matches LXMessage.unpack behavior)
        XCTAssertTrue(restored.incoming,
                      "incoming flag must be true after unpackFromFile")
    }

    // MARK: - determineCompressionSupport tests

    /// Test 5: No recalled app data → autoCompress == true after call.
    func testDetermineCompressionSupportNoAppDataDefaultsTrue() throws {
        let original = try makeMessage(content: "Compression test")
        // No Reticulum stack is running, so recallAppData returns nil.
        original.autoCompress = false  // set to false first so we can verify the method changes it
        original.determineCompressionSupport()
        XCTAssertTrue(original.autoCompress,
                      "autoCompress must default to true when no app data is recalled")
    }

    /// Test 6: Method is callable without crash on a fresh LXMessage.
    func testDetermineCompressionSupportDoesNotCrash() throws {
        let original = try makeMessage(content: "No crash")
        // Should not throw or crash
        XCTAssertNoThrow(original.determineCompressionSupport())
    }

    /// Test 7: Calling determineCompressionSupport twice is idempotent.
    func testDetermineCompressionSupportIdempotent() throws {
        let original = try makeMessage(content: "Idempotent")
        original.determineCompressionSupport()
        let firstResult = original.autoCompress
        original.determineCompressionSupport()
        XCTAssertEqual(original.autoCompress, firstResult,
                       "determineCompressionSupport must be idempotent")
    }

    /// Test 8: autoCompress property has a default value of true on a new LXMessage.
    func testAutoCompressDefaultIsTrue() throws {
        let original = try makeMessage()
        XCTAssertTrue(original.autoCompress,
                      "autoCompress must default to true on a new LXMessage")
    }
}
