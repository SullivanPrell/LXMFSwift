# LXMFSwift

> **Reticulum and LXMF are the work of [Mark Qvist](https://github.com/markqvist).** This is an
> independent, community Swift implementation of LXMF — **not an official Reticulum project**.
> The canonical project and reference (Python) implementation live at
> **[github.com/markqvist/LXMF](https://github.com/markqvist/LXMF)**, part of the broader
> **[Reticulum](https://github.com/markqvist/Reticulum)** network created by Mark; please look
> there first to understand the protocol itself.

A Swift port of [LXMF](https://github.com/markqvist/LXMF) — the **Lightweight
Extensible Message Format** — wire-compatible with the Python reference
implementation.

[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%2B%20%7C%20macOS%2013%2B-blue)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![CI](https://github.com/SullivanPrell/LXMFSwift/actions/workflows/ci.yml/badge.svg)](https://github.com/SullivanPrell/LXMFSwift/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/badge/coverage-77%25-green)](#testing)
[![License](https://img.shields.io/badge/license-Reticulum-lightgrey)](LICENSE)

LXMF is the messaging layer of the Reticulum ecosystem — the format behind apps
like Sideband and NomadNet. It provides store-and-forward, end-to-end encrypted
messages that can travel opportunistically, over a direct link, or be parked on a
**propagation node** for later pickup, all without any central server.

**LXMFSwift** implements that format and its router in Swift, on top of
[ReticulumSwift](https://github.com/SullivanPrell/ReticulumSwift). A message sent
from a Swift node is delivered to, and readable by, a Python LXMF node (and vice
versa).

This is part of the [ReticulumSwift stack](https://github.com/SullivanPrell/ReticulumSwift#the-reticulumswift-stack).

## Status

LXMFSwift implements the full LXMF 0.9.9 message format and router — both a
client and a propagation-node server — and is wire-compatible with the Python
reference. Covered by 398 unit tests (~77% line coverage).

- LXMessage: wire-compatible pack/unpack, packed-container files, URI, QR, compression.
- Stamps & tickets: proof-of-work stamps, ticket stamps, cost enforcement.
- LXMRouter: opportunistic / direct / propagated delivery, announces, auth,
  priority, ignore lists, message lifecycle.
- Propagation node: peering, sync, offer/get protocol; client-side sync.

## Requirements

- Swift 5.9+, iOS 16+ / macOS 13+
- Depends on [ReticulumSwift](https://github.com/SullivanPrell/ReticulumSwift) 1.0.0+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/SullivanPrell/LXMFSwift.git", from: "1.0.0")
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "LXMF", package: "LXMFSwift")])
]
```

## Quick start

```swift
import ReticulumSwift
import LXMF

// A running Reticulum stack (see ReticulumSwift docs).
let stack = Reticulum(configuration: .init(storagePath: storageURL))
try stack.start()
let identity = try stack.loadOrCreateIdentity()

// The LXMF router drives delivery on top of Transport.
let router = LXMRouter(transport: stack.transport)
let myAddress = try router.register(
    identity: identity,
    transport: stack.transport,
    displayName: "Alice"
)

// Receive messages.
router.onMessageReceived = { message in
    let text = String(data: message.content, encoding: .utf8) ?? ""
    print("message from \(message.sourceHash.map { String(format: "%02x", $0) }.joined()): \(text)")
}

// Compose and send a message to a peer's delivery destination.
let peer = peerDeliveryDestination          // resolved from an announce / address
let message = LXMessage(
    destination: peer,
    source: myAddress,
    content: "Hello over Reticulum",
    title: "Greetings"
)
try router.send(message)
```

`message.desiredMethod` can be set to `.opportunistic`, `.direct`, or
`.propagated`; left unset, the router picks based on what's reachable. See
[docs/USAGE.md](docs/USAGE.md) for delivery methods, propagation nodes, stamps,
tickets, and the message store.

## Documentation

- [docs/USAGE.md](docs/USAGE.md) — delivery methods, propagation, stamps, tickets
- [CONTRIBUTING.md](CONTRIBUTING.md) — dev workflow and conventions

## Testing

```sh
swift test
# develop against a sibling ReticulumSwift checkout instead of the published release:
RETICULUM_LOCAL_DEPS=1 swift test
```

## License

Released under the **Reticulum License** (no use in harm-capable systems; no use
for AI/ML training datasets). See [LICENSE](LICENSE). LXMFSwift is a derivative
work of [LXMF](https://github.com/markqvist/LXMF) by Mark Qvist; see [NOTICE](NOTICE).
