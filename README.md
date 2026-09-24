# LXMFSwift

> **Reticulum and LXMF are the work of [Mark Qvist](https://github.com/markqvist).** LXMFSwift
> is a community translation of his Python LXMF implementation into Swift. It's
> **not an official Reticulum project** and **not a clean-room implementation**. The
> canonical project and reference implementation live at
> **[github.com/markqvist/LXMF](https://github.com/markqvist/LXMF)**, part of the broader
> **[Reticulum](https://github.com/markqvist/Reticulum)** network created by Mark Qvist;
> start there to understand the protocol itself. See [Provenance](#provenance).

A Swift port of [LXMF](https://github.com/markqvist/LXMF)—the **Lightweight
Extensible Message Format**—built to interoperate with the Python reference
implementation.

[![Platforms](https://img.shields.io/badge/platforms-iOS%2016%2B%20%7C%20macOS%2013%2B-blue)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![CI](https://github.com/SullivanPrell/LXMFSwift/actions/workflows/ci.yml/badge.svg)](https://github.com/SullivanPrell/LXMFSwift/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/badge/coverage-77%25-green)](#testing)
[![License](https://img.shields.io/badge/license-Reticulum-lightgrey)](LICENSE)

LXMF is the messaging layer of the Reticulum ecosystem—the format behind apps
like Sideband and NomadNet. It provides store-and-forward, end-to-end encrypted
messages that can travel opportunistically, over a direct link, or be parked on a
**propagation node** for later pickup, all without any central server.

**LXMFSwift** translates that format and its router into Swift, on top of
[ReticulumSwift](https://github.com/SullivanPrell/ReticulumSwift). In the
interoperability suite, Swift and Python LXMF nodes deliver messages to each other in
both directions.

This is part of the [ReticulumSwift stack](https://github.com/SullivanPrell/ReticulumSwift#the-reticulumswift-stack).

## Status

LXMFSwift is **experimental**. It tracks Python LXMF 1.1.0 and covers the message
format and the router, which runs as a client or as a propagation node. It hasn't had an
independent security review. The Python implementation is the authority on how LXMF
behaves. Where this port differs from it, the port is wrong. Unit tests cover about
77% of lines.

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

- [docs/USAGE.md](docs/USAGE.md)—delivery methods, propagation, stamps, tickets
- [CONTRIBUTING.md](CONTRIBUTING.md)—dev workflow and conventions

## Testing

```sh
swift test
# develop against a sibling ReticulumSwift checkout instead of the published release:
RETICULUM_LOCAL_DEPS=1 swift test
```

## Provenance

LXMFSwift is a translation of the Python LXMF implementation, not an independent or
clean-room implementation of the protocol. Its authors wrote it from the Python source,
and the code follows that source closely: types, functions, constants, and control flow
mirror their Python counterparts, and doc comments in 8 of 10 of the files in `Sources/`
cite the Python file, function, or line that each part translates. That makes it a
derivative work of LXMF. See [NOTICE](NOTICE).

Its authors wrote most of the code with machine assistance (Claude Code). Commits made
that way carry a `Co-Authored-By: Claude` trailer.

## License

Released under the **Reticulum License** (no use in harm-capable systems; no use
for AI/ML training datasets). See [LICENSE](LICENSE). LXMFSwift is a derivative
work of [LXMF](https://github.com/markqvist/LXMF) by Mark Qvist, as
[Provenance](#provenance) describes. See [NOTICE](NOTICE).
