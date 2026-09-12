//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXMFSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import ReticulumSwift
import XCTest

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
    // appName is the module-level "lxmf" constant from LXMF.swift
    let handler = LXMFDeliveryAnnounceHandler(router: makeRouter())
    XCTAssertTrue(handler.aspectFilter!.hasPrefix(appName + "."))
  }

  func testPropagationAspectFilterMatchesAPPNAME() {
    let handler = LXMFPropagationAnnounceHandler(router: makeRouter())
    XCTAssertTrue(handler.aspectFilter!.hasPrefix(appName + "."))
  }
}
