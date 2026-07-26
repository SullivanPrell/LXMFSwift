# Changelog

All notable changes to LXMFSwift are documented here. This project follows
[Semantic Versioning](https://semver.org).

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
