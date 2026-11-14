//===----------------------------------------------------------------------===//
// Copyright (c) 2026 LXMFSwift contributors.
//
// Licensed under the Reticulum License. See LICENSE in the repository root for
// the full license text, and NOTICE for attribution of the upstream project
// this file is derived from.
//
// SPDX-License-Identifier: LicenseRef-Reticulum
//===----------------------------------------------------------------------===//

import Foundation
import ReticulumSwift

/// LXMF proof-of-work stamps over ReticulumSwift's `Stamps`.
///
/// Mirrors Python's `LXStamper.py` (LXMF 1.3.0, `:9-24`), which wraps `RNS.Stamps`. Costs and
/// values are fractional: a value is floored to the 1/256 grid, and a stamp is valid when its
/// value reaches the cost.
public enum LXStamper {
  /// Python: `WORKBLOCK_EXPAND_ROUNDS = 3000`.
  public static let defaultExpandRounds: Int = 3000
  /// Python: `WORKBLOCK_EXPAND_ROUNDS_PN = 1000`.
  public static let pnExpandRounds: Int = 1000
  /// Python: `STAMP_SIZE`, 32 bytes.
  public static let stampSize: Int = 32

  /// Python: `stamp_workblock`.
  public static func stampWorkblock(material: Data, expandRounds: Int = defaultExpandRounds) -> Data
  {
    Stamps.stampWorkblock(material, expandRounds: expandRounds)
  }

  /// Python: `stamp_value`.
  public static func stampValue(workblock: Data, stamp: Data) -> Double {
    Stamps.stampValue(workblock: workblock, stamp: stamp)
  }

  /// Python: `stamp_valid`.
  public static func stampValid(stamp: Data, targetCost: Double, workblock: Data) -> Bool {
    Stamps.stampValid(stamp: stamp, targetCost: targetCost, workblock: workblock)
  }

  /// A stamp over `messageID` meeting `stampCost`, or `nil` for a cost outside
  /// `0...Transport.stampCostCap`.
  public static func generateStamp(
    messageID: Data, stampCost: Double,
    expandRounds: Int = defaultExpandRounds
  ) -> Data? {
    generateStamp(material: messageID, targetCost: stampCost, expandRounds: expandRounds)?.stamp
  }

  /// Python: `generate_stamp(message_id, stamp_cost, expand_rounds)` (`LXStamper.py:23-24`),
  /// which returns the stamp and the value it reached.
  ///
  /// - Returns: `nil` for a cost outside `0...Transport.stampCostCap`, or when `isCancelled`
  ///   turns true.
  public static func generateStamp(
    material: Data,
    targetCost: Double,
    expandRounds: Int = defaultExpandRounds,
    isCancelled: () -> Bool = { false }
  ) -> (stamp: Data, value: Double)? {
    Stamps.generateStamp(
      material, stampCost: targetCost, expandRounds: expandRounds, size: stampSize,
      isCancelled: isCancelled)
  }

  // MARK: - Propagation node stamp validation

  /// Expand rounds for propagation-node stamp validation (lower than message stamps).
  ///
  /// Python: `WORKBLOCK_EXPAND_ROUNDS_PN = 1000` (same as `pnExpandRounds`).
  public static let pnStampExpandRounds: Int = 1000

  /// Expand rounds for peering-key validation.
  ///
  /// Python: `WORKBLOCK_EXPAND_ROUNDS_PEERING = 25`.
  public static let peeringExpandRounds: Int = 25

  /// The material a peering key is computed over: **receiver ‖ sender**, 16 + 16 = 32 bytes.
  ///
  /// Both Python sites agree on that order even though they name the halves differently:
  ///
  /// - the generator (`LXMPeer.py:258`) builds `self.identity.hash + self.router.identity.hash`
  ///—the *remote peer it is dialling* first, itself second;
  /// - the validator (`LXMRouter.py:2300`) builds `self.identity.hash + remote_identity.hash`
  ///—*itself* first, the sender second.
  ///
  /// Both are receiver-then-sender. The argument labels here state which is which so the two
  /// call sites cannot silently disagree.
  ///
  /// These are **Identity** hashes—`Identity.truncated_hash(public_key)`, 16 bytes
  /// (`RNS/Identity.py:784`)—not destination hashes. An `LXMPeer` is keyed by its *propagation
  /// destination* hash, so the identity must be recalled from the transport first.
  public static func peeringID(receiverIdentityHash: Data, senderIdentityHash: Data) -> Data {
    receiverIdentityHash + senderIdentityHash
  }

  /// Validate a peering key for peer-to-peer sync.
  ///
  /// Mirrors Python's `validate_peering_key(peering_id, peering_key, target_cost)`.
  ///
  /// - Parameters:
  ///   - peeringID: Material = local_identity_hash + remote_identity_hash
  ///   - peeringKey: The stamp data to validate
  ///   - targetCost: Minimum required stamp value
  /// - Returns: true if the peering key is valid
  public static func validatePeeringKey(peeringID: Data, peeringKey: Data, targetCost: Double)
    -> Bool
  {
    let workblock = stampWorkblock(material: peeringID, expandRounds: peeringExpandRounds)
    return stampValid(stamp: peeringKey, targetCost: targetCost, workblock: workblock)
  }

  /// Validate a single propagation-node stamp on incoming message data.
  ///
  /// Mirrors Python's `validate_pn_stamp(transient_data, target_cost)`.
  ///
  /// - Parameters:
  ///   - transientData: Raw LXMF bytes + appended 32-byte stamp
  ///   - targetCost: Minimum required stamp value
  /// - Returns: (transientID, lxmfData, stampValue, stamp) on success, nil on failure
  public static func validatePNStamp(transientData: Data, targetCost: Double) -> (
    transientID: Data, lxmfData: Data, stampValue: Double, stamp: Data
  )? {
    // Minimum = LXMF overhead + stamp
    let minLen = LXMessage.lxmfOverhead + stampSize
    guard transientData.count > minLen else { return nil }

    let lxmfData = transientData.prefix(transientData.count - stampSize)
    let stamp = transientData.suffix(stampSize)
    let transientID = Hashes.fullHash(lxmfData)
    let workblock = stampWorkblock(material: transientID, expandRounds: pnStampExpandRounds)

    guard stampValid(stamp: stamp, targetCost: targetCost, workblock: workblock) else {
      return nil
    }
    let value = stampValue(workblock: workblock, stamp: stamp)
    return (
      transientID: transientID,
      lxmfData: Data(lxmfData),
      stampValue: value,
      stamp: Data(stamp)
    )
  }

  /// Validate a list of raw transient_data entries for propagation node acceptance.
  ///
  /// Mirrors Python's `validate_pn_stamps(transient_list, target_cost)`.
  ///
  /// - Returns: Array of (transientID, lxmfData, stampValue, stamp) for each valid entry.
  public static func validatePNStamps(
    transientList: [Data], targetCost: Double
  ) -> [(transientID: Data, lxmfData: Data, stampValue: Double, stamp: Data)] {
    transientList.compactMap { validatePNStamp(transientData: $0, targetCost: targetCost) }
  }
}
