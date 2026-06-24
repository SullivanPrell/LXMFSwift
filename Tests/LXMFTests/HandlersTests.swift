import XCTest
import ReticulumSwift
@testable import LXMF

/// Tests for LXMFDeliveryAnnounceHandler and LXMFPropagationAnnounceHandler.
/// Python reference: LXMF/Handlers.py

final class HandlersTests: XCTestCase {

    private func makeRouter() -> LXMRouter { LXMRouter(transport: Transport()) }

    // MARK: - LXMFDeliveryAnnounceHandler

    func testDeliveryHandlerAspectFilter() {
        // Python: self.aspect_filter = APP_NAME + ".delivery"
        // APP_NAME = "lxmf" → "lxmf.delivery"
        let handler = LXMFDeliveryAnnounceHandler(router: makeRouter())
        XCTAssertEqual(handler.aspectFilter, "lxmf.delivery")
    }

    func testDeliveryHandlerReceivePathResponses() {
        // Python: self.receive_path_responses = True
        let handler = LXMFDeliveryAnnounceHandler(router: makeRouter())
        XCTAssertTrue(handler.receivePathResponses)
    }

    func testDeliveryHandlerHoldsRouter() {
        let router = makeRouter()
        let handler = LXMFDeliveryAnnounceHandler(router: router)
        XCTAssertTrue(handler.router === router)
    }

    // MARK: - LXMFPropagationAnnounceHandler

    func testPropagationHandlerAspectFilter() {
        // Python: self.aspect_filter = APP_NAME + ".propagation"
        // APP_NAME = "lxmf" → "lxmf.propagation"
        let handler = LXMFPropagationAnnounceHandler(router: makeRouter())
        XCTAssertEqual(handler.aspectFilter, "lxmf.propagation")
    }

    func testPropagationHandlerReceivePathResponses() {
        // Python: self.receive_path_responses = True
        let handler = LXMFPropagationAnnounceHandler(router: makeRouter())
        XCTAssertTrue(handler.receivePathResponses)
    }

    func testPropagationHandlerHoldsRouter() {
        let router = makeRouter()
        let handler = LXMFPropagationAnnounceHandler(router: router)
        XCTAssertTrue(handler.router === router)
    }

    // MARK: - Aspect filter matches expected LXMF app name

    func testDeliveryAspectFilterMatchesAPPNAME() {
        // APP_NAME is the module-level "lxmf" constant from LXMF.swift
        let handler = LXMFDeliveryAnnounceHandler(router: makeRouter())
        XCTAssertTrue(handler.aspectFilter!.hasPrefix(APP_NAME + "."))
    }

    func testPropagationAspectFilterMatchesAPPNAME() {
        let handler = LXMFPropagationAnnounceHandler(router: makeRouter())
        XCTAssertTrue(handler.aspectFilter!.hasPrefix(APP_NAME + "."))
    }
}
