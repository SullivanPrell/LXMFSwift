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

/// A delivered message that carried a ticket holds back the next one for `TICKET_INTERVAL`.
///
/// The DELIVERED branch of `process_outbound` records `last_deliveries[destination]` when the
/// message had `include_ticket` and a ticket field (`LXMRouter.py:3063-3069`), and
/// `generate_ticket` returns `None` inside the interval (`:1235-1240`).
final class TicketDeliveryTests: XCTestCase {

  private func deliver(includeTicket: Bool) throws -> (SingleNode, Data) {
    let node = try SingleNode()
    let message = try node.enqueueMessage(method: .direct)
    let destination = message.destinationHash
    let entry = try XCTUnwrap(node.router.generateTicket(destinationHash: destination))
    message.includeTicket = includeTicket
    message.fields[Int(Field.ticket.rawValue)] = [entry.expiry, entry.ticket] as [Any]
    message.state = .sent
    node.router.markDelivered(message)
    XCTAssertEqual(message.state, .delivered)
    return (node, destination)
  }

  func testADeliveredTicketHoldsBackTheNextOne() throws {
    let (node, destination) = try deliver(includeTicket: true)
    XCTAssertNil(node.router.generateTicket(destinationHash: destination))
  }

  func testAMessageThatDidNotAskForATicketDoesNotCount() throws {
    let (node, destination) = try deliver(includeTicket: false)
    XCTAssertNotNil(node.router.generateTicket(destinationHash: destination))
  }
}
