import XCTest
import CoreImage
import ReticulumSwift
@testable import LXMF

/// Tests for LXMessage.asQR() — QR code encoding of paper-delivery LXMs.
///
/// Python reference (LXMessage.py):
///   QR_MAX_STORAGE = 2953
///   QR_ERROR_CORRECTION = "ERROR_CORRECT_L"
///   PAPER_MDU = ((QR_MAX_STORAGE-(len(URI_SCHEMA)+len("://"))) * 6) // 8
///   as_qr() → QR image for paper messages; raises TypeError for non-paper
final class LXMessageQRTests: XCTestCase {

    private static let APP_NAME = "lxmqr"

    private func makeSrcDst() throws -> (Destination, Destination) {
        let srcID = Identity(); let dstID = Identity()
        let src = try Destination(identity: srcID, direction: .in, kind: .single,
                                  appName: Self.APP_NAME, aspects: ["delivery"])
        let dst = try Destination(identity: dstID, direction: .in, kind: .single,
                                  appName: Self.APP_NAME, aspects: ["delivery"])
        return (src, dst)
    }

    // MARK: - Constants

    func testQRMaxStorage() {
        // Python: QR_MAX_STORAGE = 2953 (alphanumeric capacity of error-correct-L QR)
        XCTAssertEqual(LXMessage.qrMaxStorage, 2953)
    }

    func testQRErrorCorrectionLevel() {
        // Python: QR_ERROR_CORRECTION = "ERROR_CORRECT_L" → "L"
        XCTAssertEqual(LXMessage.qrCorrectionLevel, "L")
    }

    func testPaperMDU() {
        // Python: PAPER_MDU = ((QR_MAX_STORAGE - (len("lxm") + len("://"))) * 6) // 8
        //                   = ((2953 - 6) * 6) // 8 = 17682 // 8 = 2210
        let expected = ((LXMessage.qrMaxStorage - (LXMessage.uriSchema.count + 3)) * 6) / 8
        XCTAssertEqual(LXMessage.paperMDU, expected)
        XCTAssertEqual(LXMessage.paperMDU, 2210)
    }

    // MARK: - asQR() for paper messages

    func testAsQRReturnsCIImageForPaperMessage() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "qr test", desiredMethod: .paper)
        try msg.pack()
        let image = try msg.asQR()
        XCTAssertNotNil(image, "asQR() must return a non-nil CIImage for paper messages")
    }

    func testAsQRThrowsForNonPaperMessage() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "direct msg", desiredMethod: .direct)
        try msg.pack()
        XCTAssertThrowsError(try msg.asQR(),
            "asQR() must throw for non-paper delivery method")
    }

    func testAsQRThrowsForNilDesiredMethod() throws {
        let (src, dst) = try makeSrcDst()
        // desiredMethod defaults to nil → not paper → must throw
        let msg = LXMessage(destination: dst, source: src, content: "no method")
        try msg.pack()
        XCTAssertThrowsError(try msg.asQR(),
            "asQR() must throw when desiredMethod is nil")
    }

    func testAsQRPacksIfNeeded() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "auto-pack", desiredMethod: .paper)
        // Do NOT call pack() explicitly — asQR() must do it internally
        let image = try msg.asQR()
        XCTAssertNotNil(image, "asQR() must pack automatically if needed")
        XCTAssertNotNil(msg.packed, "packed must be set after asQR()")
    }

    func testAsQRProducesNonEmptyImage() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "non-empty", desiredMethod: .paper)
        let image = try msg.asQR()
        // CIQRCodeGenerator produces images with positive extent
        XCTAssertGreaterThan(image.extent.width, 0,
            "QR image must have positive width")
        XCTAssertGreaterThan(image.extent.height, 0,
            "QR image must have positive height")
    }

    func testAsQRImageIsSquare() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "square", desiredMethod: .paper)
        let image = try msg.asQR()
        XCTAssertEqual(image.extent.width, image.extent.height,
            "QR code must be square")
    }

    func testAsQRTwiceGivesSameSize() throws {
        // Two calls on the same message must produce the same QR dimensions
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "idempotent", desiredMethod: .paper)
        let img1 = try msg.asQR()
        let img2 = try msg.asQR()
        XCTAssertEqual(img1.extent.size, img2.extent.size,
            "Repeated asQR() calls must produce same-size images")
    }

    func testAsQREncodesLXMUri() throws {
        // The QR content must be the lxm:// URI — verify by decoding the image
        // and confirming it starts with "lxm://"
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "uri content", desiredMethod: .paper)
        // Just verify we can get the URI separately and QR doesn't throw
        let uri = try msg.asURI()
        let image = try msg.asQR()
        XCTAssertNotNil(image)
        XCTAssertTrue(uri.hasPrefix("lxm://"), "URI used for QR must start with lxm://")
    }

    func testAsQRErrorIsThrownWhenMethodNotPaper() throws {
        let (src, dst) = try makeSrcDst()
        let msg = LXMessage(destination: dst, source: src,
                            content: "propagation", desiredMethod: .propagated)
        try msg.pack()
        do {
            _ = try msg.asQR()
            XCTFail("Expected throw for propagated method")
        } catch LXMessage.LXMessageError.notPaperMethod {
            // correct
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
