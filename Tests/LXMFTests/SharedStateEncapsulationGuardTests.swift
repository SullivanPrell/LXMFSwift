import XCTest
@testable import LXMF

/// `swift_devel/bugs/055`, step 7 — the rule, enforced, over both owners.
///
/// The router already documented this discipline in prose: a comment explains that peers must not
/// touch the message store directly, and names the four accessors they must use instead. The
/// discipline was breached anyway, on the very property the comment is about, and stayed breached
/// for the life of the propagation node. Prose is not enforcement.
///
/// One rule over two files, deliberately. A check that knew only about `LXMRouter` would be a fact
/// about one file rather than a rule, and `LXMPeer` carried nineteen instances of the same defect.
final class SharedStateEncapsulationGuardTests: XCTestCase {

    private typealias Owner = (label: String, file: String, lock: String, names: [String])

    private var owners: [Owner] {
        [("LXMRouter", "LXMRouter.swift", "lock",     SharedStateInventory.router.map(\.name)),
         ("LXMPeer",   "LXMPeer.swift",   "peerLock", SharedStateInventory.peer.map(\.name))]
    }

    /// A `public var` with a setter, i.e. a stored property or a computed one with a `set` block.
    ///
    /// A read-only computed property is `public var name: T {` followed by a body with no `set`.
    /// A stored one is `public var name: T = …` or `public var name: T` with no brace.
    private func publiclySettable(_ lines: [String], property name: String) -> String? {
        for (i, raw) in lines.enumerated() {
            let l = SharedStateInventory.stripComment(raw)
            guard l.range(of: #"^\s*public\s+var\s+\#(name)\b"#, options: .regularExpression) != nil
            else { continue }

            // Stored: no opening brace on the declaration line.
            guard l.contains("{") else { return "line \(i + 1): stored `public var` — \(l.trimmingCharacters(in: .whitespaces))" }

            // Computed: look for a `set` accessor before the closing brace.
            var depth = 0
            for j in i..<lines.count {
                let body = SharedStateInventory.stripComment(lines[j])
                depth += body.filter { $0 == "{" }.count - body.filter { $0 == "}" }.count
                if j > i, body.range(of: #"^\s*(nonmutating\s+)?set\b"#, options: .regularExpression) != nil {
                    return "line \(j + 1): computed property with a public setter"
                }
                if depth <= 0 && j > i { break }
            }
            return nil
        }
        return nil   // not declared as `public var` at all — private storage, or a `func`
    }

    // MARK: - 7.1

    func testNoLockGuardedPropertyIsPubliclySettable() throws {
        for o in owners {
            let lines = try SharedStateInventory.sourceLines(o.file)
            XCTAssertFalse(o.names.isEmpty, "the \(o.label) inventory is empty — this guard would pass vacuously")

            var offenders: [String] = []
            for name in o.names {
                if let why = publiclySettable(lines, property: name) {
                    offenders.append("\(o.label).\(name) — \(why)")
                }
            }

            XCTAssertTrue(offenders.isEmpty,
                          """
                          these are mutated by \(o.label) under `\(o.lock)` and publicly settable:

                          \(offenders.joined(separator: "\n"))

                          A consumer assigning to one races the owner's own writes, and a Swift \
                          `Dictionary` write is not atomic — the reader can observe a partially \
                          rehashed table, which is a segfault rather than a stale value. Make it \
                          private storage behind a lock-taking accessor; if it must stay writable, \
                          give it a lock-taking method the way `staticPeers` has `setStaticPeers`.
                          """)
        }
    }

    /// The guard must be seen to fail. This runs its own logic against a synthetic source rather
    /// than mutating the real one, so the demonstration is part of the suite instead of a note
    /// somebody has to trust.
    func testTheGuardActuallyFiresOnAPubliclySettableProperty() {
        let stored = [
            "final class Thing {",
            "    public var propagationEntries: [Data: Int] = [:]",
            "}",
        ]
        XCTAssertNotNil(publiclySettable(stored, property: "propagationEntries"),
                        "a stored `public var` must be reported")

        let computedWithSetter = [
            "final class Thing {",
            "    public var peers: [Data: Int] {",
            "        get { lock.lock(); defer { lock.unlock() }; return _peers }",
            "        set { lock.lock(); _peers = newValue; lock.unlock() }",
            "    }",
            "    private var _peers: [Data: Int] = [:]",
            "}",
        ]
        XCTAssertNotNil(publiclySettable(computedWithSetter, property: "peers"),
                        "a computed property with a public setter must be reported — it is still an external write path")

        let readOnly = [
            "final class Thing {",
            "    public var peers: [Data: Int] {",
            "        lock.lock(); defer { lock.unlock() }",
            "        return _peers",
            "    }",
            "    private var _peers: [Data: Int] = [:]",
            "}",
        ]
        XCTAssertNil(publiclySettable(readOnly, property: "peers"),
                     "a read-only locked accessor is the shape being asked for and must pass")

        let privateOnly = ["final class Thing {", "    private var _peers: [Data: Int] = [:]", "}"]
        XCTAssertNil(publiclySettable(privateOnly, property: "peers"))
    }

    // MARK: - 7.2 — the inventory and the source must agree in both directions

    /// Properties that are `public var` on an owner and deliberately **not** lock-guarded.
    ///
    /// Without this, a lock-guarded property that nobody adds to the inventory is invisible to
    /// 7.1: the guard only looks at names it is given. Every `public var` therefore has to be
    /// either inventoried or exempt, with the reason stated here.
    private static let exemptions: [String: [String: String]] = [
        "LXMRouter.swift": [
            "onMessageReceived":                 "callback slot; set once at wiring time",
            "outboundPropagationNode":           "client-side configuration; the router never takes `lock` for it",
            "propagationTransferState":          "client-side sync progress, single-threaded on the client path",
            "propagationTransferProgress":       "as above",
            "propagationTransferSize":           "as above",
            "propagationTransferMaxMessages":    "as above",
            "deliveryPerTransferLimit":          "configuration",
            "retainSyncedOnNode":                "configuration",
            "wantsDownloadOnPathAvailableFrom":  "client-side download intent",
            "enforceRatchets":                   "configuration",
            "storagePath":                       "configuration; its `didSet` loads persisted state",
            "messagePath":                       "configuration",
            "messageStorageLimit":               "configuration",
            "propagationPerTransferLimit":       "configuration",
            "propagationPerSyncLimit":           "configuration",
            "propagationStampCost":              "configuration — the ROUTER's own, distinct from LXMPeer's announced term of the same name",
            "propagationStampCostFlexibility":   "configuration — as above",
            "peeringCost":                       "configuration — as above",
            "autopeer":                          "configuration",
            "maxPeeringCost":                    "configuration",
            "prioritiseRotatingUnreachablePeers":"configuration",
            "autopeerMaxdepth":                  "configuration",
        ],
        "LXMPeer.swift": [
            "msgSize":         "field of `PropagationEntry`, a struct — reached only through the router's locked accessors, so a snapshot copies it",
            "handledPeers":    "as above",
            "unhandledPeers":  "as above",
        ],
    ]

    func testEveryPublicVarIsEitherInventoriedOrExempt() throws {
        for o in owners {
            let lines = try SharedStateInventory.sourceLines(o.file)
            let inventoried = Set(o.names)
            let exempt = Set(Self.exemptions[o.file]?.keys ?? [:].keys)

            var unclassified: [String] = []
            for (i, raw) in lines.enumerated() {
                let l = SharedStateInventory.stripComment(raw)
                guard let m = l.range(of: #"^\s*public\s+(private\(set\)\s+|internal\(set\)\s+)?var\s+\w+"#,
                                      options: .regularExpression) else { continue }
                // `public private(set) var` has no external write path; it is not a hazard.
                if l.contains("private(set)") || l.contains("internal(set)") { continue }
                let name = String(l[m].split(separator: " ").last!)
                if inventoried.contains(name) || exempt.contains(name) { continue }
                // A read-only computed property is already the shape the rule asks for. It is not
                // exempt from scrutiny — it can still read guarded storage without the lock, which
                // is what `name` did — but that is
                // `testEveryComputedAccessorThatReadsGuardedStorageTakesTheLock`'s question, not
                // this one.
                if publiclySettable(lines, property: name) == nil && l.contains("{") { continue }
                unclassified.append("\(o.file):\(i + 1): \(name)")
            }

            XCTAssertTrue(unclassified.isEmpty,
                          """
                          these are `public var` on \(o.label) and are neither in the inventory nor \
                          on the exemption list:

                          \(unclassified.joined(separator: "\n"))

                          Decide which. If \(o.label) ever touches it under `\(o.lock)` it belongs in \
                          the inventory and 7.1 will require it to be encapsulated; if it is \
                          configuration the owner never locks, add it to `exemptions` with the \
                          reason. Leaving it unclassified is how the twelfth instance of this \
                          defect gets in — 7.1 only checks names it is given.
                          """)
        }
    }

    /// A public accessor that reads lock-guarded storage must take the lock.
    ///
    /// This is the defect wearing the fix's clothes, and it is not hypothetical: encapsulating
    /// `metadata` left `LXMPeer.name` reading `_metadata` with no lock — a read-only computed
    /// property, so 7.1 had nothing to say about it, while the router writes that field from the
    /// announce-callback thread. Converting a property is not finished until everything that reads
    /// its new storage has been re-examined.
    ///
    /// An accessor that reaches guarded state *indirectly* — by calling a method that locks — is
    /// fine and is recognised by delegating rather than naming `_x`.
    func testEveryComputedAccessorThatReadsGuardedStorageTakesTheLock() throws {
        for o in owners {
            let lines = try SharedStateInventory.sourceLines(o.file)
            var offenders: [String] = []

            for (i, raw) in lines.enumerated() {
                let head = SharedStateInventory.stripComment(raw)
                guard head.range(of: #"^\s*public\s+(private\(set\)\s+|internal\(set\)\s+)?var\s+\w+.*\{\s*$"#,
                                 options: .regularExpression) != nil else { continue }
                let name = head.replacingOccurrences(of: #"^\s*public\s+(private\(set\)\s+|internal\(set\)\s+)?var\s+"#,
                                                     with: "", options: .regularExpression)
                              .prefix(while: { $0 != ":" && $0 != " " })

                // Body of this accessor.
                var depth = 0, body: [String] = []
                for j in i..<lines.count {
                    let l = SharedStateInventory.stripComment(lines[j])
                    depth += l.filter { $0 == "{" }.count - l.filter { $0 == "}" }.count
                    if j > i { body.append(l) }
                    if depth <= 0 && j > i { break }
                }
                let text = body.joined(separator: "\n")

                let reads = o.names.filter {
                    // its own backing store is expected; any OTHER guarded store is the question
                    $0 != String(name)
                    && text.range(of: #"(?<![\w])_\#($0)\b"#, options: .regularExpression) != nil
                }
                // Reading its own `_name` counts too — that is the whole point of the accessor.
                let readsOwn = text.range(of: #"(?<![\w])_\#(name)\b"#, options: .regularExpression) != nil
                guard readsOwn || !reads.isEmpty else { continue }
                guard o.names.contains(String(name)) || !reads.isEmpty || readsOwn else { continue }

                if !text.contains("\(o.lock).lock()") {
                    offenders.append("\(o.file):\(i + 1): `\(name)` reads guarded storage \(reads.isEmpty ? "_\(name)" : reads.map { "_\($0)" }.joined(separator: ", ")) without taking `\(o.lock)`")
                }
            }

            XCTAssertTrue(offenders.isEmpty,
                          """
                          \(offenders.joined(separator: "\n"))

                          Encapsulating a property moves its storage behind a lock; every accessor \
                          that reads that storage has to take the lock too, or the read is the \
                          same race the encapsulation removed.
                          """)
        }
    }

    /// Every access to a `_`-prefixed backing store must hold the owner's lock, or be on a
    /// construction path where the object is not yet reachable from another thread.
    ///
    /// This is the broadest of the guards and the one that found the most. Hand-running it during
    /// task 8 turned up four real defects that everything else had passed over, because none of
    /// them is a *setter* and none is a computed *property*:
    ///
    /// - `toBytes()` read nine fields outside the lock, four of them under a comment asserting
    ///   they had no runtime writer.
    /// - `sync()` read the three announced-term fields outside the lock, under the same
    ///   now-false comment.
    /// - a local named `offered` had been renamed to `_offered` by the conversion and was
    ///   shadowing the property — behaviour unchanged, but one deletion away from silently
    ///   binding to the wrong thing.
    ///
    /// `isUnderLock` is brace-depth aware, so it is not fooled by same-line `lock(); x; unlock()`
    /// or by an `unlock()` inside a branch that returns.
    func testEveryBackingStoreAccessIsUnderTheLockOrOnAConstructionPath() throws {
        // Members that run before the object is reachable from any other thread. `enablePropagation`
        // is the router's setup: it loads persisted peers and stats before the job loop starts.
        let constructionPaths = ["init(", "from(bytes:", "enablePropagation("]

        for o in owners {
            let lines = try SharedStateInventory.sourceLines(o.file)
            var offenders: [String] = []

            for (i, raw) in lines.enumerated() {
                let l = SharedStateInventory.stripComment(raw)
                for name in o.names {
                    guard let r = l.range(of: #"(?<![\w])_\#(name)\b"#, options: .regularExpression)
                    else { continue }
                    // The declaration of the backing store itself.
                    if l.range(of: #"^\s*private\s+var\s+_\#(name)\b"#, options: .regularExpression) != nil { continue }

                    let col = l.distance(from: l.startIndex, to: r.lowerBound)
                    if SharedStateInventory.isUnderLock(lines, line: i + 1, column: col, lockName: o.lock) { continue }

                    // Which member is it in?
                    var enclosing = "<file scope>"
                    var k = i
                    while k > 0 {
                        if lines[k].range(of: #"^    (@discardableResult\s+)?(public |internal |private |fileprivate )?(static )?(func |init\(|deinit)"#,
                                          options: .regularExpression) != nil {
                            enclosing = lines[k].trimmingCharacters(in: .whitespaces)
                            break
                        }
                        k -= 1
                    }
                    if constructionPaths.contains(where: { enclosing.contains($0) }) { continue }

                    offenders.append("\(o.file):\(i + 1) in `\(enclosing.prefix(60))`: \(l.trimmingCharacters(in: .whitespaces).prefix(70))")
                }
            }

            XCTAssertTrue(offenders.isEmpty,
                          """
                          these read or write `\(o.label)` backing storage without holding \
                          `\(o.lock)`, outside any construction path:

                          \(offenders.joined(separator: "\n"))

                          Encapsulation moves the storage behind the lock; a `_x` reached without \
                          it is the same race the encapsulation removed. If the site genuinely \
                          runs before the object is shared, add its member to `constructionPaths` \
                          and say why.
                          """)
        }
    }

    /// The exemption list must not outlive the properties it excuses.
    func testNoExemptionNamesAPropertyThatIsGone() throws {
        for (file, entries) in Self.exemptions {
            let lines = try SharedStateInventory.sourceLines(file)
            for (name, reason) in entries {
                XCTAssertFalse(SharedStateInventory.declarationLines(lines, property: name).isEmpty,
                               "\(file) exempts `\(name)` (\(reason)) but no longer declares it — a ledger that outlives its entries stops being a record")
            }
        }
    }

    /// The three names that exist on both an owner and something else.
    ///
    /// `swift_devel/bugs/055` step 6 asked for a sweep proving no direct assignment to shared
    /// state survives in the test suite. A textual sweep cannot answer that: 21 assignments remain
    /// and every one is to a *different type* that shares a name — `router.peeringCost` is the
    /// router's configuration, `msg.state` is an `LXMessage`. The real proof is that the package
    /// compiles: every inventoried property is get-only, so an assignment to one is a build error.
    ///
    /// What this pins is the premise that makes those 21 safe — that each colliding name is
    /// inventoried on `LXMPeer` and exempt on `LXMRouter`. If one of the router's scalars ever
    /// becomes lock-guarded, this fails and the 21 sites need revisiting.
    func testTheCollidingNamesAreGuardedOnThePeerAndExemptOnTheRouter() {
        let colliding = ["propagationStampCost", "propagationStampCostFlexibility", "peeringCost"]
        let peerNames = Set(SharedStateInventory.peer.map(\.name))
        let routerExempt = Set(Self.exemptions["LXMRouter.swift"]?.keys ?? [:].keys)
        let routerNames = Set(SharedStateInventory.router.map(\.name))

        for name in colliding {
            XCTAssertTrue(peerNames.contains(name), "\(name) should be an inventoried LXMPeer property")
            XCTAssertTrue(routerExempt.contains(name), "\(name) should be an exempt LXMRouter configuration scalar")
            XCTAssertFalse(routerNames.contains(name),
                           """
                           `LXMRouter.\(name)` is now lock-guarded. The test suite still assigns to \
                           it directly in several places, which were safe only while it was \
                           unguarded configuration — revisit them.
                           """)
        }
    }
}
