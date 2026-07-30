# Changelog

All notable changes to LXMFSwift are documented here. This project follows
[Semantic Versioning](https://semver.org).

## [Unreleased] — 1.3.0

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
