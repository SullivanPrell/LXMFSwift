# Changelog

All notable changes to LXMFSwift are documented here. This project follows
[Semantic Versioning](https://semver.org).

## [Unreleased]

### A stale link is no longer treated as a dead one

ReticulumSwift 1.10.2 changed what `Link.status == .stale` means. It used to be a marker set
immediately before teardown; it is now a **live, recoverable** state — the link is held for a
grace tick and any inbound packet promotes it back to `.active` (`RNS/Link.py:753-755`, `:939`).

This router shipped the same day still classifying `.stale` with `.closed` and `.failed`: it
dropped its reference to the link, burned a delivery attempt, and requested a path — while RNS
was still holding that session open and might have recovered it a moment later. The two releases
disagreed about the same enum case.

Python never had the problem because it branches only on `ACTIVE` and `CLOSED`
(`LXMRouter.py:2784`, `:2797`): a stale link falls through both branches and is simply waited
out. The direct-link and propagation-link paths now do the same, and
`reapClosedOutboundPropagationLink` no longer reaps a stale link. Nothing is lost from
`bugs/020`'s guarantee: a transfer that genuinely stops progressing is still terminated by
`cleanLinks(syncStallTimeout:)`, which is the layer that owns that job.

Found by the post-release adversarial audit — a cross-package interaction that neither package's
own test suite could see.

### The outbound retry ladder runs on the reference's numbers and gate (`bugs/013 §9`)

Python LXMF 1.1.0 paces delivery with `DELIVERY_RETRY_WAIT = 10`, `PATH_REQUEST_WAIT = 7` and
`MAX_PATHLESS_TRIES = 1` (`LXMRouter.py:30-34`); the port shipped 12, 15 and 2 — the 12 being
LXMF's pre-0.2.8 retry wait — so a Swift sender made two pathless sends before its first path
request, spaced retries 12 s apart and sat 15 s after every path request. Delivery to a pathless
destination converged roughly twice as slowly as the reference's. The constants now match, each
pinned by test against the Python values.

Two neighbours fixed in the same pass:

- **The attempts gate is `<=`, and lives in one seam.** The reference gates every method branch
  with `delivery_attempts <= MAX_DELIVERY_ATTEMPTS` (`LXMRouter.py:2736,:2766,:2853`), giving a
  message six real attempts before `fail_message` (`:2564-2571`); the port failed fast on `>=`,
  giving five. Worse, the opportunistic path-request branch sat *in front of* the gate, so a
  pathless opportunistic message never failed at all — it re-requested a path forever. All three
  branches now guard with `<=` and give up through one `failMessage(_:)`, the port of
  `fail_message`: progress reset, dequeue, `.failed` unless already `.rejected`, failed callback.

- **Stale-path rediscovery** (`LXMRouter.py:2743-2752`) had no Swift counterpart. When an
  opportunistic message has a path that still has not delivered by
  `MAX_PATHLESS_TRIES + 1` attempts, the reference treats the path as stale: drop it, then
  re-request it half a second later (`rediscover_job`). Without the branch, a Swift sender
  holding a path entry that outlived the route retried into the dead path until the message
  failed, where Python recovers and delivers. This was the only piece that could strand a
  message outright.

Python maps a closed outbound propagation link onto the sync state machine in `clean_links`
(`LXMRouter.py:991-1000`); the port's `onClosed` handlers cleared the link reference and left
`propagationTransferState` wherever it was, so "Sync Now" against an unreachable node spun for
the lifetime of the process. One method — `reapClosedOutboundPropagationLink()` — now carries
the reference's mapping (complete acknowledges to idle; in flight fails; an existing failure
stands), called from both `onClosed` handlers immediately and from `cleanLinks` on the
reference's own schedule. A deliberate cancel stays a cancel for the reference's own reason:
`cancelPropagationNodeRequests` clears the reference before tearing down, so the closure finds
nothing to map.

Found while proving it: **`propagationTransferState = .requestSent` sat after
`link.request(...)`**, and the response callback can run inside that call — so a sync that
completed inline had its `.done` stomped back to `.requestSent`. The reference has the same
line order (`:520`) as a latent race its network never resolves inline. The write moved before
the callout.

Also new, port-only and recorded as such: `cleanLinks(syncStallTimeout:)` bounds a sync on a
*live* link that has stopped moving (default 240 s, above the RNS inactivity teardown so the
watchdog gets the first move). The reference has nothing for this case; a caller waiting on a
terminal state would wait forever.

### A propagation node ingests and proves single-packet uploads (`bugs/021`)

Python's `propagation_link_established` sets **both** a packet callback and the resource
callbacks (`LXMRouter.py:2189-2193`); the port wired only the resource path, so the plaintext
of every single-packet upload was dropped without a proof — and Python clients take the packet
path for any message whose container fits 319 bytes, an ordinary short chat message. The node
worked for long messages and lost short ones, presenting as random.

`handleInboundPropagationPacket` mirrors `propagation_packet` (`:2234-2260`): validate every
stamp, ingest through the same `ingestPropagatedLXM` the resource path uses, prove only when
the whole set validated, answer `ERROR_INVALID_STAMP` and tear down otherwise. Deliberately
narrower than the resource path — no autopeering, no peer credit, no throttle — because the
reference's packet path is a client surface, not a peer one.

### The suite's ThreadSanitizer count is zero, and can be gated on (`bugs/056`)

Two data races in **test code** made the suite report 2–3 TSan warnings on good code, so a real
regression could hide in the noise:

- `ProofGatedDeliveryTests` captured a plain `var Bool` in the delivery callback — written on a
  link thread, read on the test thread. All three occurrences use a lock-guarded `Flag` now, not
  just the one ThreadSanitizer happened to flag.
- `PropagationAnnouncePeeringTests` polled `pendingOutbound` from a background thread while the
  router mutated it under `lock`. The property was the last of the `bugs/055` shape left outside
  the inventory: every router mutation already held `lock`, and the unguarded piece was the raw
  `private(set)` getter. It is now private storage behind the same lock-taking snapshot accessor
  as the other thirty, inventoried and guard-checked. (Internal API only — `pendingOutbound` was
  never `public`.)

Verified as three complete `swift test --sanitize=thread` runs: **0, 0, 0 warnings** against the
previous release's 2, 3, 2.

## [1.6.0] — shared state stops being public

`bugs/055`. Thirty properties across `LXMRouter` and `LXMPeer` were `public var` over state their
owner only ever touches under its own lock. Each is now private storage behind a **read-only
accessor that takes the lock and returns a snapshot**.

**BREAKING, source-level.** Every existing *read* still compiles. Every external *write* is now a
compile error. There are no consumers of these setters in this repository — verified across
`RetiOS/`, `NomadNetSwift/` and `LXSTSwift/` — which is what made this the moment to do it.

### The one write Python's consumers actually make

Python's attributes are writable, so the question that decides whether this is a parity break is
not "does Python permit a consumer to write these" but "does any Python consumer *do* it". Across
the reference tree — `nomadnet`, `lxmd`, `LXMF`'s own handlers — the answer is **one line**:
NomadNet's peer-list "sync now" action, which sets `peer.next_sync_attempt = time.time()-1` and
then calls `peer.sync()` on a thread (`nomadnet/ui/textui/Network.py:1818`). Everything else those
consumers do with a router or a peer is a read, a constructor argument, or a method call.

That capability is preserved as **`LXMPeer.requestImmediateSync()`** — the intent rather than the
field assignment. It does not start the sync (`sync()` is public, as in Python) and does not clear
`syncBackoff`, because Python's line does not and a nudge that silently reset the backoff would
retry a failing peer at the base interval forever. The grace check Python gates the action on reads
`lastSyncAttempt`, which stays publicly readable.

### Why it mattered

A Swift `Dictionary` write is not atomic. A consumer reading `router.propagationEntries` while the
router writes does not get a stale value, it gets **SIGSEGV** — reproducibly, without
ThreadSanitizer, on a partially rehashed table. Python needs none of this: `propagation_entries` is
a plain public attribute (`LXMRouter.py:222`) and the GIL makes a `dict` get/set atomic. The Swift
lock is a mechanism divergence, and a `public var` was a hole straight through it.

On `LXMPeer` it was not a hazard awaiting an external consumer — **`LXMRouter` was the consumer.**
It wrote thirteen peer fields from announce and inbound-propagation callback threads with
`peerLock` not held, while that peer's own `sync()` read seven of them under it. Those are now
three mutators — `adoptAnnouncedTerms`, `clearSyncBackoff`, `creditInbound` — each taking the lock
once for the whole set, because nine separate locked setters would leave a peer observable
half-updated.

`staticPeers` keeps a write path, since it is operator configuration Python takes as a constructor
argument (`LXMRouter.py:211-219`). What it lost is the unsynchronized one:
`setStaticPeers` / `addStaticPeer` / `removeStaticPeer`.

### Also fixed, found while fixing the above

- **`LXMPeer.toBytes()` serialized nine fields outside `peerLock`**, four of them under a comment
  asserting they had no runtime writer. The comment was load-bearing — it was the reason the reads
  were unguarded. The router has always been that writer.
- **`LXMPeer.sync()` read the three announced-term fields outside the lock**, under the same false
  comment.
- **The re-peering path cleared `syncBackoff` and `nextSyncAttempt` cross-object.** Those are the
  sync machine's own — `sync()` computes `nextSyncAttempt = now + syncBackoff` under `peerLock` —
  so clearing them from the announce thread could tear that deadline.
- Two doc comments on `LXMRouter` were swapped: `propagationEntries` was documented as the peer
  table and `peers` as the message store.

### Enforcement, not discipline

The router already documented this rule in prose, and was breached anyway on the very property the
comment names. `SharedStateEncapsulationGuardTests` checks it instead, over **both** files under
one rule: no inventoried property is publicly settable; every `public var` is inventoried or
exempt with a stated reason; every computed accessor that reads guarded storage takes the lock; and
every backing-store access is under the lock or on a named construction path.

592 tests, 0 failures. ThreadSanitizer clean on the propagation-concurrency and snapshot suites.

No wire or on-disk format change: `toBytes()` emits the same keys in the same order with the same
values, and only reads them atomically now.

## [1.5.0] — a propagation node that pushes

The other half of `1.4.0`. That release filled the peer table; this one drains it. **Between two
Swift nodes, messages now move.**

**BREAKING.** The outbound sync machine is no longer public API. `LXMPeer.OfferResponse`,
`processOfferResponse`, `linkEstablished`, `linkClosed`, `buildOffer` and
`resourceConcluded(success:dataSizeBytes:)` are gone, and `link`, `lastOffer` and
`currentlyTransferringMessages` are `private`. They were public, complete, and called only by
tests — which is exactly how the defect below survived a year of green suites. `sync()` is the
only entry point; `generatePeeringKey()` and `reapStalledSyncLink(maxInactivity:)` are the only
other non-private symbols on the path, and a test asserts that.

`peeringKey` is `private(set)`; `linkEstablishmentRate` is `public private(set)`;
`syncTransferRate` keeps an internal setter. `LXMRouter.getWeight` returns `Double`, not
`TimeInterval`.

### Fixed

- **A propagation node could never initiate a sync** (`bugs/054`). `LXMPeer.sync()` opened no
  link — the code said so in a comment — and `peeringKey` had **no writer anywhere in `Sources/`**,
  so `peering_key_ready` was false forever and `sync()` returned at its first guard. A node
  accepted syncs, served clients and answered offers, but never pushed its store; between two
  Swift nodes nothing moved at all. Ported from `LXMPeer.py:227-546`: the peering-key generator,
  the re-entrant `sync()` pump, a real `Link`, the offer request, every offer-response branch with
  its side effects, and the resource transfer.

- **Every peer error code was misread on the client path too** (extends `bugs/053`). `isPeerError`
  carried its own copy of the wire decoding. Both paths now go through one `LXMPeerError(msgPack:)`.

- **`getWeight` returned the receive timestamp**, not `priorityWeight * ageWeight * size`
  (`LXMRouter.py:1056-1067`). Offers went out oldest-first regardless of size, and `prioritise()`
  had no effect on peer sync at all.

- **A stalled sync link was never collected.** A peer's own link is in neither `directLinks` nor
  `activePropagationLinks`, and `syncPeers` selects only `state == .idle` — so a peer stalled
  mid-sync was out of the rotation for the life of the process. `cleanLinks` now reaps it.

- **The peering key was not persisted**, so every restart redid a full proof of work for every
  peer — minutes each at the default cost of 18 — and the node could sync to nobody until it
  finished. `propagation_sync_limit` now also falls back to `propagation_transfer_limit` on
  restore, as the announce path already did.

- **A peer answering `ERROR_NO_IDENTITY` to everything could overflow the stack.** The recovery
  branch re-identified and re-synced unconditionally. Python has the same shape and only looks
  bounded because CPython cannot deliver a response from inside `link.request`; over a synchronous
  transport it is a crash. Re-identify once per link, then give up.

- **Two data races TSan found while every assertion passed.** `peeringKey` and
  `peeringKeyGenerationsStarted` were written under `peerLock` from the proof-of-work queue and
  read unguarded through their public getters.

### Deliberate deviations from the reference

Both documented at the code:

- **No blocking path grace.** Python sleeps 7.5 s inside `sync()` and re-checks
  (`LXMPeer.py:298`). That would stall the whole LXMF job loop, whose tick is 4 s, and the 24 s
  `syncPeers` cadence already exceeds the grace it buys. Strictly slower to notice a new path,
  never wrong.
- **`ERROR_INVALID_KEY` gets a branch.** Python has none: the integer falls into
  `for transient_id in response`, raises, and lands in the except at `:482-490`, which resets
  without touching the messages — so the refused key is re-offered unchanged forever. Here the key
  is discarded and rebuilt, and the offered messages stay unhandled.
- **Single-flight key generation.** Python starts a daemon thread per postponed pass, all
  serialising through a multi-second proof of work.
- **Parallel stamp search.** Python picks single-threaded on Darwin because its multi-process path
  needs `fork`, not because the algorithm does. A random preimage is wire-invisible.

### What still does not work

- **`bugs/055`** (new, open): `LXMRouter.propagationEntries` is a `public var` over state the
  router only ever touches under its lock, so an external reader on another thread races its
  writes. TSan-proven. Reading through `peerEntry` / `peerEntryExists` is safe; the fix needs 41
  source uses and 33 test sites moved and is its own change.
- The propagation-throttle interop cell is still deferred: exercising `ERROR_THROTTLED` end to end
  needs the tri-test node contract to expose per-node stamp costs on both the Python and Swift
  sides, which neither does today.

### Testing

571 tests, 0 failures (from 531). `swift test --sanitize=thread --filter PeerOutboundSync`: 0
races. Every step was verified red first by a named mutation — deleting the `Link.initiate` call
fails 14 tests; writing `state` after the callouts fails 4; stripping the propagation stamp before
sending fails 6.

The first **captured Python vectors** in this package (`PythonPeeringVectors`): the peering
workblock is built identically by this package's generator and its validator, so a divergence from
the reference is invisible to every Swift-only test and surfaces only as `ERROR_INVALID_KEY` from
a Python peer, with nothing the sender can log.

tri-test gains `test_a_message_uploaded_to_the_swift_node_reaches_the_python_one` — a real Python
propagation node validating a peering key a Swift node generated, then receiving the resource it
ships. It XFAILs strictly against 1.4.0.

## [1.4.0] — a propagation node that actually peers

**Requires ReticulumSwift 1.9.0.** A propagation node peers off the announces it hears, and before
1.9.0 a node also heard its own — so it peered with itself (`ReticulumSwift bugs/047`).

**BREAKING.** Three changes, all of them deliberate:

- `LXMRouter.addPeer` and `removePeer` are now **internal**. `peer(destinationHash:timestamp:…)`
  and `unpeer(destinationHash:timestamp:)` are the public construction and removal points, because
  they are where the reference's peering conditions live — the peering-cost ceiling, the `maxPeers`
  bound and the peering timebase. A caller that reached `addPeer` directly bypassed all three.
- `LXMRouter.peerDistributionQueue` is now `[(transientID: Data, fromPeer: LXMPeer?)]`.
- **An existing node with more peers than `maxPeers` will rotate down to the bound on first run.**
  There was no bound before, so a long-running node may hold more than 20 peers; rotation drops the
  worst-performing ones over successive passes. This is the intended behaviour and not data loss —
  the messages stay in the store.

### What still does not work

Stated plainly, because the peer table this release fills is real and only half the machinery
drains it: **a node built on this port still cannot INITIATE a sync.** `LXMPeer.sync()` opens no
link, no peering key is ever generated, and `buildOffer` / `linkEstablished` /
`processOfferResponse` / `resourceConcluded` have no production callers. A node accepts syncs,
serves clients and answers offers correctly; it does not push its store to its peers. That is
`bugs/054` and the next release's work.

So: this release makes a node a correct *participant* in a propagation mesh in the receive
direction, and an accurate advertiser of itself. It does not yet make it a full peer.

### Fixed

- **A node never peered with anyone** (`bugs/042`). `addPeer` had zero call sites outside its own
  tests, anywhere in the tree. `autopeer` and `autopeer_maxdepth` existed only as lines inside an
  example-configuration *string*. Autopeering now happens on the incoming-sync path
  (`LXMRouter.py:2366-2375`).

- **A node ignored every announce it heard** (`bugs/046`). The reference peers on two paths, and
  the port had only the reactive one. Reactive peering cannot start on its own — peering is what
  causes a sync, and a sync is what causes reactive peering — so two nodes built on this port sat
  with empty tables waiting for each other, and everything `bugs/042` fixed was unreachable
  between them. Both registered handlers now reach one router method carrying `Handlers.py:41-99`
  whole: the outbound-PN trigger, autopeering with its path-response and depth gates, static-peer
  refresh, and unpeering a node that moves out of range or says it has stopped propagating.

- **The advertised costs defaulted to zero, which no Python peer can satisfy** (`bugs/048`). A zero
  peering cost is not "no proof of work required" — `peering_key_ready` opens with
  `if not self.peering_cost: return False` (`LXMPeer.py:228`), so a node advertising 0 is one every
  Python peer postpones syncing to, forever, with no error on either side. Now `PEERING_COST = 18`,
  `PROPAGATION_COST = 16` with the `PROPAGATION_COST_MIN = 13` floor on the initialiser argument,
  and `PROPAGATION_COST_FLEX = 3`.

- **A peer was offered back the messages it had just sent** (`bugs/049`). The distribution queue
  carried no origin. Threading it through was not sufficient on its own: `addToMessageStore` was
  constructing every entry with `unhandledPeers: Array(peers.keys)`, so the store was the *first*
  writer of the unhandled set and the exclusion had nothing left to exclude. The reference builds
  the entry empty (`LXMRouter.py:2518`) and lets the distribution flush be the only writer; it is
  the only writer here now. Peering also moved before ingest, as in the reference, because
  `from_peer` can only exclude a peer that exists by the time its messages are stored.

- **A brand-new peer was seeded with the entire message store** (`bugs/050`). Python's `peer()`
  seeds nothing; `unhandled_messages` is derived from the store's per-entry lists, so a new peer
  starts empty and receives only what arrives after peering. A node holding 5,000 messages that
  autopeered with a remote used to offer it all 5,001 on the next pass — including the message that
  remote had just uploaded.

- **A configured static peering never happened** (`bugs/051`). `staticPeers` was a set that
  rotation and sync selection filtered against and nothing ever wrote to: no peer entry, no path
  request, no error. Activation now runs at the end of `enablePropagation` as in the reference, and
  requests a path for any peer never heard from — one that was offline at startup never announces,
  so the solicited path response is the only way its terms are learned.

- **The peer table was read at startup and never written** (`bugs/052`). `savePeers` was reachable
  only from `disablePropagation`, which has no caller anywhere in the tree, so the port had a
  complete reader for a file nothing produced. Lost on every restart: each peer's handled and
  unhandled transient-ID sets, its peering timebase and its measured transfer rate.

- **Every refusal a peer sent read as "the peer wants nothing"** (`bugs/053`). LXMF error codes are
  all above 127, so msgpack writes them as `uint8` and the decoder returns `.uint`; the response
  handler matched `case .int`, which matches neither. `ERROR_THROTTLED` produced no back-off,
  `ERROR_NO_IDENTITY` no re-identify, `ERROR_NO_ACCESS` no unpeer.

- **A node could not throttle a misbehaving remote** (`bugs/044`). The port decoded
  `ERROR_THROTTLED` as a client and had no path that emitted it, so a transfer of invalid-stamp
  messages cost full validation over the whole set and could be retried at any rate.

- **The peer table had no bound and never rotated** (`bugs/043`). `maxPeers`,
  `prioritiseRotatingUnreachablePeers` and `rotatePeers` are ported whole.

- **`syncPeers` synced every peer at once** (`bugs/045`), where the reference selects one per pass
  from the two fastest plus the equal-unknown-speed set, and culls peers past `MAX_UNREACHABLE`.

- **The job loop ran three of the reference's ten routines** (`bugs/019`). The schedule is now data
  compared against `LXMRouter.py:880-911` by test. Eight dispatch; `processDeferredStamps` is
  scheduled with a recorded reason (the port generates stamps synchronously and has no queue to
  drain), and `cleanLinks` and `flushQueues` were written for it.

### Added — one recorded divergence

`savePeers` runs on the job schedule, which the reference does not do — it persists on exit, via
`atexit` and the SIGINT/SIGTERM handlers. That suits a daemon stopped politely; this port's primary
consumer is an iOS app, terminated without notice and unable to run an exit handler at all.
`LXMRouter.Job` gains `additionReason`, and a test requires every scheduled routine the reference
lacks to declare why it is there — a divergence with a recorded reason is a decision, one without
is a mistake nobody has noticed yet.

## [1.3.0] — paper messages encrypted, delivery gated on proof

**Requires ReticulumSwift 1.8.0.** Proof-gated delivery needs link-packet receipts, which do
not exist before it.

**BREAKING.** Two API changes and one wire-format change, all of them deliberate:

- `LXMessage.fromURI(_:)` is now `fromURI(_:destination:)`. There is no key-less form, because
  the payload after the destination hash is ciphertext — a decoder that appeared to work
  without a key could only ever report a success it did not achieve.
- `LXMRouter.ingestLXMURI(_:)` returns `Bool` (`@discardableResult`) so a caller can tell a
  delivery from a drop, and throws `noMatchingDeliveryDestination` for a URI addressed
  elsewhere.
- **Existing Swift-produced paper URIs become unreadable.** That is the point: they were never
  readable by Python either.

### Fixed

- **Paper messages carried the message in cleartext** (`bugs/026`). Python encrypts the payload
  to the destination identity before base64-encoding it
  (`packed[:16] + destination.encrypt(packed[16:])`, `LXMessage.py:449-451`); this port had no
  paper branch at all, so `asURI()` and `asQR()` base64-encoded the raw plaintext wire bytes. A
  printed or photographed QR exposed the title, body, fields and sender hash to anyone who read
  it — on a feature whose entire purpose is to cross a channel the sender does not control —
  and no Python client could ingest one. `pack()` now builds the paper form and throws
  `paperMDUExceeded` past `PAPER_MDU` rather than handing back a URI that silently will not fit
  in a QR code.

- **The paper route bypassed every inbound check** (`bugs/026`). `ingestLXMURI` called the
  application callback directly, so ticket ingest, the ignore list and duplicate suppression
  were all skipped: an ignored sender's paper message was delivered, and the same QR scanned
  twice was delivered twice. It now decrypts with the addressed delivery destination and routes
  through the same seam as every other inbound path, with stamp enforcement waived for paper as
  the reference does (`LXMRouter.py:2489`).

- **A message was reported delivered when `send()` returned** (`bugs/014`). Returning from a
  send call is not evidence of delivery: the packet may be dropped by the very next hop while
  the sender's screen says it arrived. `.delivered` is now reached only from a validated
  receiver proof (`LXMessage.py:482-483`, `:563-568`), and the timeout path tears the link down
  and returns the message to `.outbound` for another attempt (`:616-621`).

### Changed

- **`.delivered` now dwells in `.sending` until the recipient proves receipt, and a retry after
  a timeout is visible.** This will read as a regression to anyone who has not been told: the
  checkmark used to appear before anything left the device. `onStateChange` reports every
  transition so an application can show the dwell and the retry honestly.

## [1.2.0] — LXMF 1.1.0 parity: inbound resource tracking and live sync progress

**Requires ReticulumSwift 1.5.0.** The inbound registry keys on the resource
hash reported when a transfer starts, and the sync progress reads a response
size published mid-transfer — neither exists before 1.5.0. Against an older
ReticulumSwift this package still compiles, but the registry collapses every
concurrent transfer onto one empty key and the transfer size stays nil.

### Added

- **Inbound message-resource tracking.** `inboundCount()`, `inboundResources()`,
  `cancelInbound(resourceHash:)` and `cancelAllInbound()`, plus the periodic reap
  (Python's `JOB_RESOURCE_INTERVAL = 2`). A large message over a slow multi-hop
  path can take minutes; this lets a UI show what is arriving and lets the user
  abort something unwanted instead of waiting it out.
- **`acknowledgeSyncCompletion(resetState:failureState:)`.** Without it a
  finished sync left its byte count and progress in place, and the next sync
  rendered the previous transfer's size until its first progress callback landed.
  A failure state stays visible unless `resetState` is passed, matching Python.

### Fixed

- **Transient-ID caches grew without bound.** `locallyDeliveredTransientIDs` was
  a timestamp-less `Set`, so nothing could expire and the whole set was persisted
  forever. Python has always written a `{id: timestamp}` dict.

  **Storage format change:** the persisted `local_deliveries` file moves from a
  msgpack array to a msgpack map. Upgrading is safe — a legacy array is stamped
  as of migration time rather than discarded, because discarding re-delivers
  every message the node has already seen. **Downgrading to 1.1.4 or earlier
  silently wipes the delivered cache and re-delivers everything.**
- **A pruned propagation-node message was re-ingested** the next time any peer
  offered it. Added the missing `locallyProcessedTransientIDs` tombstone.
- **Propagation sync progress was only readable after the sync finished.**
  `propagationTransferSize` was read in the message-get *response* callback,
  i.e. once the transfer had completed — precisely when a progress display no
  longer needs it. Python attaches `progress_callback=self.message_get_progress`
  to the message-get request and publishes state, progress and size from there.

## [1.1.0] – [1.1.4]

Released without changelog entries; see the GitHub releases for those tags.

## [1.0.0] — Initial public release

First public release of LXMFSwift — a Swift port of
[LXMF](https://github.com/markqvist/LXMF) (the Lightweight Extensible Message
Format), wire-compatible with the Python reference (LXMF 0.9.9).

### Highlights

- **LXMessage** — wire-compatible `pack()` / `unpack()`, packed-container format,
  URI encode/decode, compression, transport-encryption determination, QR delivery.
- **Stamps & tickets** — proof-of-work stamps (`LXStamper`), ticket-based stamps,
  stamp cost enforcement, and the full ticket lifecycle API.
- **LXMRouter** — delivery routing across opportunistic, direct, and propagated
  methods; announce handling; authentication, priority, and ignore lists;
  outbound queue and message lifecycle (progress / cancel).
- **Propagation node** — full propagation-node server (peering, sync, offer/get
  protocol) and client-side propagation-node sync.

Covered by 398 unit tests (~77% line coverage). Built on ReticulumSwift 1.0.0.
