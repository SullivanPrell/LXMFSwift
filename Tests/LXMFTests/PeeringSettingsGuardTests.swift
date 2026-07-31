import XCTest
@testable import LXMF
import ReticulumSwift

/// `swift_devel/bugs/042`, second half — a configuration key the port documents is a key the port
/// reads.
///
/// `autopeer` and `autopeer_maxdepth` sat in `LXMDConfig.exampleConfig` for the life of the port
/// with nothing behind them, so a node started from the configuration the port itself generates
/// behaved as `autopeer = no`. That is `bugs/030` at key scale: an entire `[reticulum]` section the
/// port generated and ignored.
///
/// LXMFSwift parses no configuration file — `LXMDConfig` is constants and a template string, and
/// the package has no executable target — so the guard cannot be "is parsed". It is: every peering
/// key in the template is *accounted for*, either by naming a router setting that exists or by
/// recording, with a reason, that the port does not implement it. A key that is neither fails.
final class PeeringSettingsGuardTests: XCTestCase {

    func testEveryPeeringKeyTheTemplateDocumentsIsAccountedFor() {
        let documented = Self.peeringKeysIn(LXMDConfig.exampleConfig)
        XCTAssertFalse(documented.isEmpty,
                       "no peering keys were found in the template — the scanner is broken, which "
                       + "would make this guard pass by finding nothing to check")

        let unaccounted = documented.filter { LXMDConfig.peeringSettings[$0] == nil }
        XCTAssertTrue(unaccounted.isEmpty,
                      """
                      \(unaccounted.sorted()) appear in the configuration this package hands an \
                      operator, and are neither backed by a router setting nor recorded as \
                      unimplemented. A documented key that nothing reads is worse than one that is \
                      not offered: it reads as configured.
                      """)
    }

    func testEverySettingTheLedgerNamesExistsOnTheRouter() {
        let router = LXMRouter(transport: Transport())
        let properties = Set(Mirror(reflecting: router).children.compactMap(\.label))
        XCTAssertFalse(properties.isEmpty, "reflection found no properties — the check is vacuous")

        for (key, backing) in LXMDConfig.peeringSettings {
            guard case .setting(let name) = backing else { continue }
            XCTAssertTrue(properties.contains(name),
                          """
                          the ledger says `\(key)` is backed by `LXMRouter.\(name)`, and the \
                          router has no such property — the setting was renamed or removed and the \
                          key silently stopped being read.
                          """)
        }
    }

    func testTheLedgerDoesNotClaimKeysTheTemplateDoesNotDocument() {
        let documented = Self.peeringKeysIn(LXMDConfig.exampleConfig)
        let stale = LXMDConfig.peeringSettings.keys.filter { !documented.contains($0) }
        XCTAssertTrue(stale.isEmpty,
                      """
                      \(stale.sorted()) are accounted for but no longer appear in the template. \
                      A ledger that outlives its keys stops being a record of what an operator can \
                      set.
                      """)
    }

    // MARK: - Scanner

    /// Peering-related keys in the template's `[propagation]` section, commented or not.
    ///
    /// The template comments out its optional keys, and a commented key is still a key the
    /// operator is being shown — `bugs/042`'s `autopeer` was uncommented and `max_peers` is
    /// commented, and both were equally unread.
    private static func peeringKeysIn(_ template: String) -> Set<String> {
        // Keys whose subject is peering. Deliberately a list rather than "every key in the
        // section": the section also carries storage limits and stamp costs, which are not this
        // capability's and are backed elsewhere.
        let peering: Set<String> = [
            "autopeer", "autopeer_maxdepth", "max_peers", "static_peers",
            "from_static_only", "peering_cost", "remote_peering_cost_max",
        ]

        var found: Set<String> = []
        var inPropagationSection = false
        for rawLine in template.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inPropagationSection = line == "[propagation]"
                continue
            }
            guard inPropagationSection else { continue }
            if line.hasPrefix("#") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            if peering.contains(key) { found.insert(key) }
        }
        return found
    }
}
