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

    /// One inventoried property, and what it holds.
    ///
    /// Deliberately carries **no line numbers**. The first version cited a declaration line and a
    /// locked-access line per entry, and every edit in this change shifted them — the citations
    /// were breaking faster than the thing they documented. The invariant is "the owner accesses
    /// this under its lock *somewhere*", so the check searches for that rather than trusting a
    /// coordinate. `note` is for the reader and is never asserted.
    struct Entry {
        let name: String
        let note: String

        init(_ name: String, _ note: String) { self.name = name; self.note = note }
    }

    /// Properties of `LXMRouter` that the router accesses under `LXMRouter.lock`.
    static let router: [Entry] = [
        Entry("propagationEntries",                "the message store, keyed by transient ID"),
        Entry("peers",                             "the peer table, keyed by destination hash"),
        Entry("staticPeers",                       "operator configuration; read under the lock, written by consumers"),
        Entry("throttledPeers",                    "remotes whose offers are refused until a deadline"),
        Entry("activePropagationLinks",            "inbound propagation links"),
        Entry("validatedPeerLinks",                "link IDs authenticated as peers"),
        Entry("peerDistributionQueue",             "transient IDs awaiting fan-out, with their origin peer"),
        Entry("clientPropagationMessagesReceived", "counter; incremented on the inbound path"),
        Entry("clientPropagationMessagesServed",   "counter; incremented when serving a get-request"),
        Entry("unpeeredPropagationIncoming",       "counter; unpeered inbound messages"),
        Entry("unpeeredPropagationRxBytes",        "counter; unpeered inbound bytes"),
    ]

    /// Properties of `LXMPeer` that the peer accesses under `LXMPeer.peerLock`.
    static let peer: [Entry] = [
        Entry("state",                           "the sync state machine's current state"),
        Entry("syncStrategy",                    "configuration; read under the lock"),
        Entry("alive",                           "whether the peer has been heard from"),
        Entry("lastHeard",                       "when it was last heard from"),
        Entry("nextSyncAttempt",                 "the backoff deadline"),
        Entry("lastSyncAttempt",                 "written under the lock before every guard in sync()"),
        Entry("syncBackoff",                     "the current backoff interval"),
        Entry("propagationTransferLimit",        "announced term; read under the lock in sync()"),
        Entry("propagationSyncLimit",            "announced term; read under the lock in sync()"),
        Entry("propagationStampCost",            "announced term; gates sync()"),
        Entry("propagationStampCostFlexibility", "announced term; gates sync()"),
        Entry("peeringCost",                     "announced term; gates peering-key generation"),
        Entry("offered",                         "count of messages offered"),
        Entry("outgoing",                        "count of messages sent"),
        Entry("txBytes",                         "bytes sent"),
        Entry("incoming",                        "count of messages received; see peerCrossObjectWrites"),
        Entry("rxBytes",                         "bytes received; see peerCrossObjectWrites"),
        Entry("metadata",                        "announced metadata; see peerCrossObjectWrites"),
        Entry("peeringTimebase",                 "announced timebase; see peerCrossObjectWrites"),
    ]

    /// A peer property the **router** writes directly, from a callback thread, without holding
    /// `peerLock`.
    ///
    /// This is the live defect, not a latent hazard: `LXMRouter.swift:2614-2623` writes nine peer
    /// fields from the announce-callback thread while the peer's own `sync()` reads seven of them
    /// under `peerLock`, and `:2262-2263` increments two more on the inbound propagation path.
    ///
    /// The assertion over this list is **inverted** — it proves the router's writes are
    /// unsynchronized rather than pretending they are not. Task 4.3 replaces them with
    /// `peerLock`-taking mutators, at which point the router stops naming these properties at all
    /// and the test says so; emptying this list is 4.3's completion criterion.
    ///
    /// These names are also in `peer`: they became `peerLock`-accessed the moment the seeding API
    /// landed, which is why the check below is about the router's side and not the peer's. The two
    /// lists overlap by design — this one annotates a subset of `peer` rather than partitioning it.
    struct CrossObjectWrite {
        let name: String
        let note: String

        init(_ name: String, _ note: String) { self.name = name; self.note = note }
    }

    static let peerCrossObjectWrites: [CrossObjectWrite] = [
        CrossObjectWrite("metadata",        "written by the router's announce handler"),
        CrossObjectWrite("peeringTimebase", "written by the router's announce handler"),
        CrossObjectWrite("incoming",        "incremented by the router's inbound propagation path"),
        CrossObjectWrite("rxBytes",         "incremented by the router's inbound propagation path"),
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

    /// The first access to `name` — or to its private backing store `_name` — in `lines` at
    /// `line`, as a column, or `nil` if neither is there.
    ///
    /// Both spellings count as the same state. Encapsulating a property renames the storage to
    /// `_name` and leaves `name` as a lock-taking computed accessor, so a check that looked only
    /// for the public spelling would report the state as unguarded the moment it became guarded.
    static func accessColumn(_ lines: [String], line: Int, property name: String) -> Int? {
        guard line - 1 >= 0, line - 1 < lines.count else { return nil }
        let l = stripComment(lines[line - 1])
        guard let r = l.range(of: #"(?<![\w])_?\#(name)\b"#, options: .regularExpression) else { return nil }
        return l.distance(from: l.startIndex, to: r.lowerBound)
    }

    /// The 1-based lines declaring `name` and, if it exists, its backing store `_name`.
    static func declarationLines(_ lines: [String], property name: String) -> [Int] {
        lines.indices.filter {
            stripComment(lines[$0]).range(
                of: #"^\s*(public |internal |private |fileprivate )?(private\(set\) |internal\(set\) )?var _?\#(name)\b"#,
                options: .regularExpression) != nil
        }.map { $0 + 1 }
    }

    /// The 1-based line declaring `name` (public spelling preferred), or `nil`.
    static func declarationLine(_ lines: [String], property name: String) -> Int? {
        declarationLines(lines, property: name).first
    }

    /// Every 1-based line where `name` is touched under `lockName`, ignoring its own declaration.
    ///
    /// The whole-file search is the point: the invariant is that the owner treats this as
    /// lock-protected state *somewhere*, not that it does so at one blessed coordinate.
    static func lockedAccessLines(_ lines: [String], property name: String, lockName: String) -> [Int] {
        let decls = Set(declarationLines(lines, property: name))
        var hits: [Int] = []
        for i in lines.indices where !decls.contains(i + 1) {
            guard let col = accessColumn(lines, line: i + 1, property: name) else { continue }
            if isUnderLock(lines, line: i + 1, column: col, lockName: lockName) { hits.append(i + 1) }
        }
        return hits
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
                XCTAssertNotNil(
                    SharedStateInventory.declarationLine(lines, property: e.name),
                    "\(o.label).\(e.name) is inventoried but no longer declared — it was renamed or removed")

                let sites = SharedStateInventory.lockedAccessLines(lines, property: e.name,
                                                                   lockName: o.lock)
                XCTAssertFalse(sites.isEmpty,
                    """
                    \(o.label).\(e.name) (\(e.note)) is never accessed under `\(o.lock)`. Either \
                    it is not lock-protected and does not belong in the inventory — encapsulating \
                    it would impose a cost with no race to prevent — or the last edit removed the \
                    synchronization that made it safe.
                    """)
            }
        }
    }

    /// The inverted assertion. These four are listed *because* the router writes them unguarded.
    func testTheCrossObjectWritesAreProvablyUnsynchronized() throws {
        let peerLines   = try SharedStateInventory.sourceLines("LXMPeer.swift")
        let routerLines = try SharedStateInventory.sourceLines("LXMRouter.swift")

        for w in SharedStateInventory.peerCrossObjectWrites {
            XCTAssertNotNil(SharedStateInventory.declarationLine(peerLines, property: w.name),
                            "LXMPeer.\(w.name) is inventoried but no longer declared")

            let mentioned = routerLines.indices.contains {
                SharedStateInventory.accessColumn(routerLines, line: $0 + 1, property: w.name) != nil
            }
            XCTAssertTrue(mentioned,
                          """
                          LXMRouter no longer mentions \(w.name) (\(w.note)). If task 4.3 has \
                          landed, the direct write is gone — remove this entry from \
                          `peerCrossObjectWrites`. Emptying that list is 4.3's completion criterion.
                          """)

            let guarded = SharedStateInventory.lockedAccessLines(routerLines, property: w.name,
                                                                 lockName: "peerLock")
            XCTAssertTrue(guarded.isEmpty,
                          "LXMRouter now holds peerLock at \(guarded) for \(w.name) — remove this entry")
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
        XCTAssertTrue(crossNames.isSubset(of: peerNames),
                      """
                      \(crossNames.subtracting(peerNames).sorted()) is listed as a cross-object \
                      write but is not in the peer inventory. The cross-object list annotates a \
                      subset of `peer`; a name in one and not the other means the guard test will \
                      not cover it.
                      """)

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
