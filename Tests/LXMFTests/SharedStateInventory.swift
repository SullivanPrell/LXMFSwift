import XCTest
@testable import LXMF

/// `swift_devel/bugs/055`, step 1 — the authoritative list of lock-guarded shared state.
///
/// Every later task in this change works from these lists, and the structural guard test
/// (`SharedStateEncapsulationGuardTests`) enforces the rule over exactly this set. So the list
/// itself has to be checked, not asserted: a name that is in the inventory but is *not* actually
/// lock-protected would make the guard demand encapsulation for no reason, and a name that is
/// missing is a property the guard will never look at.
///
/// The survey that sized this change used a 25-line proximity heuristic over `grep` output. That
/// is fine for sizing and useless as a specification — it produced four false "unguarded" verdicts
/// on `LXMRouter` alone, every one of them a same-line `lock.lock(); x = y; lock.unlock()` or an
/// early-return release inside a nested block. The check below re-derives lock state from the
/// source with brace-depth tracking (see `isUnderLock`).
///
/// ## The criterion: *accessed* under the lock, not *mutated* under it
///
/// "Mutated under the lock" is too narrow. `LXMRouter.staticPeers` and `LXMPeer.syncStrategy` are
/// read under their owner's lock on every use and written only by consumers — so a consumer write
/// races an owner read while the property has no under-lock mutation at all. Reading it under the
/// lock is the owner declaring it lock-protected state, and that is the criterion.
enum SharedStateInventory {

    /// One inventoried property: where it is declared, and one site where its owner touches it
    /// while holding the owner's lock.
    struct Entry {
        let name: String
        /// 1-based line of the `var` declaration.
        let declLine: Int
        /// 1-based line of an access to this property that occurs under the owner's lock.
        let lockedAccessLine: Int

        init(_ name: String, decl: Int, lockedAccess: Int) {
            self.name = name; self.declLine = decl; self.lockedAccessLine = lockedAccess
        }
    }

    /// Properties of `LXMRouter` that the router accesses under `LXMRouter.lock`.
    ///
    /// Line numbers are as of the start of `bugs/055` and are checked against the source on every
    /// run, so drift fails loudly rather than rotting.
    static let router: [Entry] = [
        Entry("propagationEntries",                decl:  285, lockedAccess: 2397),
        Entry("peers",                             decl:  289, lockedAccess: 2749),
        Entry("staticPeers",                       decl:  356, lockedAccess: 2689),
        Entry("throttledPeers",                    decl:  372, lockedAccess: 2285),
        Entry("activePropagationLinks",            decl:  375, lockedAccess: 2196),
        Entry("validatedPeerLinks",                decl:  378, lockedAccess: 2195),
        Entry("peerDistributionQueue",             decl:  386, lockedAccess: 3058),
        Entry("clientPropagationMessagesReceived", decl:  389, lockedAccess: 2268),
        Entry("clientPropagationMessagesServed",   decl:  392, lockedAccess: 3341),
        Entry("unpeeredPropagationIncoming",       decl:  395, lockedAccess: 2265),
        Entry("unpeeredPropagationRxBytes",        decl:  398, lockedAccess: 2266),
    ]

    /// Properties of `LXMPeer` that the peer accesses under `LXMPeer.peerLock`.
    static let peer: [Entry] = [
        Entry("state",                           decl: 133, lockedAccess:  809),
        Entry("syncStrategy",                    decl: 138, lockedAccess: 1286),
        Entry("alive",                           decl: 143, lockedAccess:  758),
        Entry("lastHeard",                       decl: 146, lockedAccess:  911),
        Entry("nextSyncAttempt",                 decl: 151, lockedAccess:  808),
        Entry("lastSyncAttempt",                 decl: 154, lockedAccess:  753),
        Entry("syncBackoff",                     decl: 157, lockedAccess:  807),
        Entry("propagationTransferLimit",        decl: 186, lockedAccess:  915),
        Entry("propagationSyncLimit",            decl: 189, lockedAccess:  916),
        Entry("propagationStampCost",            decl: 192, lockedAccess:  913),
        Entry("propagationStampCostFlexibility", decl: 195, lockedAccess:  914),
        Entry("peeringCost",                     decl: 198, lockedAccess:  684),
        Entry("offered",                         decl: 248, lockedAccess: 1028),
        Entry("outgoing",                        decl: 251, lockedAccess: 1280),
        Entry("txBytes",                         decl: 260, lockedAccess: 1283),
    ]

    /// A peer property that **no lock protects today**, because the peer never touches it itself
    /// and the router writes it cross-object with `peerLock` not held.
    ///
    /// This is the live defect, not a latent hazard: `LXMRouter.swift:2614-2623` writes nine peer
    /// fields from the announce-callback thread while the peer's own `sync()` reads seven of them
    /// under `peerLock`. The four listed here are the subset the peer never reads under its lock
    /// either, so they have no under-lock access anywhere and cannot satisfy the criterion above.
    ///
    /// Task 4.3 routes the router's writes through `peerLock`-taking mutators, after which these
    /// move into `peer` and this list is empty. Until then their inventory assertion is inverted:
    /// the test proves they are unsynchronized rather than pretending they are not.
    struct CrossObjectWrite {
        let name: String
        let declLine: Int
        /// 1-based line in `LXMRouter.swift` where the router writes it without holding `peerLock`.
        let routerWriteLine: Int

        init(_ name: String, decl: Int, routerWrite: Int) {
            self.name = name; self.declLine = decl; self.routerWriteLine = routerWrite
        }
    }

    static let peerCrossObjectWrites: [CrossObjectWrite] = [
        CrossObjectWrite("metadata",        decl: 243, routerWrite: 2615),
        CrossObjectWrite("peeringTimebase", decl: 160, routerWrite: 2616),
        CrossObjectWrite("incoming",        decl: 254, routerWrite: 2262),
        CrossObjectWrite("rxBytes",         decl: 257, routerWrite: 2263),
    ]
}

// MARK: - Source access and lock-state derivation

extension SharedStateInventory {

    /// `Sources/LXMF/<name>.swift`, resolved from this test file rather than from the working
    /// directory, so the check does not depend on how the suite was launched.
    static func sourceLines(_ fileName: String) throws -> [String] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LXMFTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let url = packageRoot
            .appendingPathComponent("Sources/LXMF")
            .appendingPathComponent(fileName)
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// Whether the access at `line`/`column` sits in a region that holds `lockName`.
    ///
    /// Scans from the start of the enclosing member, tracking brace depth and a stack of the
    /// depths at which the lock was acquired. The depth is what makes this correct where line
    /// counting is not:
    ///
    /// ```swift
    /// lock.lock()                                   // acquired at depth d
    /// if let existing = entries[id] {
    ///     lock.unlock()                             // released at depth d+1 — one branch only
    ///     return existing
    /// }
    /// entries[id] = entry                           // still holds the lock
    /// ```
    ///
    /// A naive counter reads that `unlock()` as balancing the `lock()` and calls the last line
    /// unguarded. It is guarded: the release belongs to a branch that returns.
    static func isUnderLock(_ lines: [String], line: Int, column: Int, lockName: String) -> Bool {
        let idx = line - 1
        guard idx >= 0, idx < lines.count else { return false }

        var start = idx
        while start > 0 {
            if lines[start].range(
                of: #"^    (@discardableResult\s+)?(public |internal |private |fileprivate )?(static )?(func |init\(|deinit)"#,
                options: .regularExpression) != nil { break }
            start -= 1
        }

        var depth = 0
        var acquiredAt: [Int] = []
        var deferredRelease = false

        for i in start...idx {
            var text = i == idx ? String(lines[i].prefix(column)) : stripComment(lines[i])

            // `defer { lock.unlock() }` holds for the remainder of the member.
            if text.contains("defer { \(lockName).unlock() }") {
                deferredRelease = true
                depth += text.filter { $0 == "{" }.count - text.filter { $0 == "}" }.count
                continue
            }

            var cursor = text.startIndex
            while cursor < text.endIndex {
                let rest = text[cursor...]
                let candidates: [(Range<String.Index>, String)] = [
                    rest.range(of: "{").map { ($0, "{") },
                    rest.range(of: "}").map { ($0, "}") },
                    rest.range(of: "\(lockName).lock()").map { ($0, "lock") },
                    rest.range(of: "\(lockName).unlock()").map { ($0, "unlock") },
                ].compactMap { $0 }

                guard let next = candidates.min(by: { $0.0.lowerBound < $1.0.lowerBound }) else { break }
                switch next.1 {
                case "{":      depth += 1
                case "}":      depth -= 1
                case "lock":   acquiredAt.append(depth)
                default:
                    // Only a release at the same depth as the acquisition ends it; a deeper one
                    // belongs to a branch and leaves the fall-through path holding the lock.
                    if let top = acquiredAt.last, depth <= top { acquiredAt.removeLast() }
                }
                cursor = next.0.upperBound
            }
        }
        return deferredRelease || !acquiredAt.isEmpty
    }

    /// A line with any `//` comment removed.
    ///
    /// Comments have to go before either the name match or the brace counting: `LXMPeer.swift:501`
    /// is a doc comment mentioning `metadata` inside a `peerLock` region, and taking it as an
    /// access made the property look guarded when nothing guards it. Braces inside comments would
    /// skew the depth for the same reason.
    static func stripComment(_ line: String) -> String {
        guard let r = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<r.lowerBound])
    }

    /// The first access to `name` in `lines` at `line`, as a column, or `nil` if it is not there.
    static func accessColumn(_ lines: [String], line: Int, property name: String) -> Int? {
        guard line - 1 >= 0, line - 1 < lines.count else { return nil }
        let l = stripComment(lines[line - 1])
        guard let r = l.range(of: #"\b\#(name)\b"#, options: .regularExpression) else { return nil }
        return l.distance(from: l.startIndex, to: r.lowerBound)
    }

    static func declares(_ lines: [String], line: Int, property name: String) -> Bool {
        guard line - 1 >= 0, line - 1 < lines.count else { return false }
        return lines[line - 1].range(of: #"\bvar \#(name)\b"#, options: .regularExpression) != nil
    }
}

// MARK: - The inventory checks itself

final class SharedStateInventoryTests: XCTestCase {

    private typealias Owner = (label: String, file: String, lock: String, entries: [SharedStateInventory.Entry])

    private let owners: [Owner] = [
        ("LXMRouter", "LXMRouter.swift", "lock",     SharedStateInventory.router),
        ("LXMPeer",   "LXMPeer.swift",   "peerLock", SharedStateInventory.peer),
    ]

    func testEveryInventoriedPropertyIsAccessedUnderItsLock() throws {
        for o in owners {
            XCTAssertFalse(o.entries.isEmpty,
                           """
                           the \(o.label) inventory is empty. Every later task in bugs/055 works \
                           from this list and the structural guard test enforces the rule over \
                           exactly this set — an empty inventory means the guard passes vacuously.
                           """)

            let lines = try SharedStateInventory.sourceLines(o.file)

            for e in o.entries {
                XCTAssertTrue(
                    SharedStateInventory.declares(lines, line: e.declLine, property: e.name),
                    "\(o.label).\(e.name): line \(e.declLine) does not declare it — the inventory has drifted from the source")

                guard let col = SharedStateInventory.accessColumn(lines, line: e.lockedAccessLine,
                                                                  property: e.name) else {
                    return XCTFail("\(o.label).\(e.name): line \(e.lockedAccessLine) does not mention it")
                }

                XCTAssertTrue(
                    SharedStateInventory.isUnderLock(lines, line: e.lockedAccessLine,
                                                     column: col, lockName: o.lock),
                    """
                    \(o.label).\(e.name): the cited access at line \(e.lockedAccessLine) is NOT \
                    under `\(o.lock)`. Either the citation is wrong, or this property is not \
                    lock-protected and does not belong in the inventory — encapsulating it would \
                    impose a cost with no race to prevent.
                    """)
            }
        }
    }

    /// The inverted assertion. These four are in the inventory *because* nothing guards them.
    func testTheCrossObjectWritesAreProvablyUnsynchronized() throws {
        let peerLines   = try SharedStateInventory.sourceLines("LXMPeer.swift")
        let routerLines = try SharedStateInventory.sourceLines("LXMRouter.swift")

        for w in SharedStateInventory.peerCrossObjectWrites {
            XCTAssertTrue(
                SharedStateInventory.declares(peerLines, line: w.declLine, property: w.name),
                "LXMPeer.\(w.name): line \(w.declLine) does not declare it")

            // The peer never touches it under its own lock...
            let selfGuarded = peerLines.indices.contains {
                guard let col = SharedStateInventory.accessColumn(peerLines, line: $0 + 1,
                                                                  property: w.name) else { return false }
                return $0 + 1 != w.declLine
                    && SharedStateInventory.isUnderLock(peerLines, line: $0 + 1, column: col,
                                                        lockName: "peerLock")
            }
            XCTAssertFalse(selfGuarded,
                           """
                           LXMPeer.\(w.name) is now accessed under `peerLock` somewhere. If task \
                           4.3 has landed, move it out of `peerCrossObjectWrites` and into `peer` \
                           — that migration is 4.3's completion criterion.
                           """)

            // ...and the router writes it without holding the peer's lock.
            guard let col = SharedStateInventory.accessColumn(routerLines, line: w.routerWriteLine,
                                                              property: w.name) else {
                return XCTFail("LXMRouter.swift:\(w.routerWriteLine) does not mention \(w.name)")
            }
            XCTAssertFalse(
                SharedStateInventory.isUnderLock(routerLines, line: w.routerWriteLine,
                                                 column: col, lockName: "peerLock"),
                "LXMRouter.swift:\(w.routerWriteLine) now holds peerLock — move \(w.name) into the `peer` inventory")
        }
    }

    func testTheInventoriesAreDisjointAndDuplicateFree() {
        let routerNames = Set(SharedStateInventory.router.map(\.name))
        let peerNames   = Set(SharedStateInventory.peer.map(\.name))
        let crossNames  = Set(SharedStateInventory.peerCrossObjectWrites.map(\.name))

        XCTAssertTrue(routerNames.intersection(peerNames).isEmpty,
                      """
                      \(routerNames.intersection(peerNames).sorted()) appear in both owners' \
                      inventories. The two owners have different locks; a name in both means the \
                      guard cannot tell which lock a violation is about.
                      """)
        XCTAssertTrue(peerNames.intersection(crossNames).isEmpty,
                      "\(peerNames.intersection(crossNames).sorted()) is both guarded and unguarded")

        XCTAssertEqual(SharedStateInventory.router.count, routerNames.count, "duplicate in router inventory")
        XCTAssertEqual(SharedStateInventory.peer.count, peerNames.count, "duplicate in peer inventory")
        XCTAssertEqual(SharedStateInventory.peerCrossObjectWrites.count, crossNames.count,
                       "duplicate in cross-object inventory")
    }

    /// Pins the derivation itself. `isUnderLock` is the only reason to believe any of the above,
    /// and the naive version of it got four `LXMRouter` sites wrong.
    func testLockDetectionHandlesTheThreePatternsThatFooledTheSurvey() {
        let src = [
            "    func a() {",                                   // 1
            "        lock.lock(); x = 1; lock.unlock()",         // 2  same-line
            "        lock.lock()",                              // 3
            "        if let e = t[k] {",                        // 4
            "            lock.unlock()",                        // 5  branch release
            "            return e",                             // 6
            "        }",                                        // 7
            "        y = 2",                                    // 8  still held
            "        lock.unlock()",                            // 9
            "        z = 3",                                    // 10 released
            "    }",                                            // 11
            "    func b() {",                                   // 12
            "        lock.lock(); defer { lock.unlock() }",      // 13
            "        w = 4",                                    // 14 held via defer
            "    }",                                            // 15
        ]
        func under(_ line: Int, _ col: Int) -> Bool {
            SharedStateInventory.isUnderLock(src, line: line, column: col, lockName: "lock")
        }
        XCTAssertTrue(under(2, 21), "same-line lock/mutate/unlock must read as held")
        XCTAssertFalse(under(2, 0), "before the lock() on that line it is not yet held")
        XCTAssertTrue(under(8, 8), "an unlock inside a returning branch must not release the fall-through path")
        XCTAssertFalse(under(10, 8), "a same-depth unlock does release it")
        XCTAssertTrue(under(14, 8), "defer { unlock } holds for the rest of the member")
    }
}
