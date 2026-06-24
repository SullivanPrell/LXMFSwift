# Changelog

All notable changes to LXMFSwift are documented here. This project follows
[Semantic Versioning](https://semver.org).

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

398 unit tests, 0 failures. Built on ReticulumSwift 1.0.0.
