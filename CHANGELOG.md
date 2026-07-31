# Changelog

All notable changes to LXMFSwift are documented here. This project follows
[Semantic Versioning](https://semver.org).

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
