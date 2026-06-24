# LXMFSwift

Swift port of [LXMF](https://github.com/markqvist/LXMF) (Python ref: LXMF 0.9.9).
Full client **and** propagation-node server. Target: wire + API parity so a Swift
LXMF node interoperates with Python LXMF nodes.

## Build & Test

```bash
swift test                          # 343 tests, 0 failures
swift test --filter <SuiteName>

# If you see SwiftShims module cache errors:
rm -rf .build && swift test
```

## Source Map

```
Sources/LXMF/
├── LXMF.swift          ← Protocol constants (Field enum, AudioMode, RendererMode,
│                          SF_*, PN_META_*, display/stamp/PN app-data helpers)
├── LXMessage.swift     ← Message encode/decode/pack/validate, URI, compression,
│                          packed-container format, ticket stamp, propagation stamp
├── LXMRouter.swift     ← Delivery routing, auth, stamp costs, outbound queue,
│                          announce API, ticket API, delivery link query
├── LXStamper.swift     ← Proof-of-work stamp generation (Argon2-like expand)
└── Handlers.swift      ← Internal announce handler types
```

## Python Reference

Source of truth for wire format. Files under `LXMF/` in
<https://github.com/markqvist/LXMF>:

```
LXMF/LXMessage.py   ← Message format + encoding
LXMF/LXMRouter.py   ← Router logic
LXMF/LXStamper.py   ← Stamp PoW
LXMF/LXMF.py        ← Protocol constants
```

## Current Parity State

**All Tasks 12–23, 39–40 complete. 343 tests, 0 failures (2026-05-26).**

### LXMessage

| Feature | Status |
|---------|--------|
| `pack()` / `unpack()` wire format | ✅ |
| `outboundTicket` → ticket-based stamp (`truncatedHash(ticket+msgID)`) | ✅ |
| `includeTicket` flag for send() | ✅ |
| `validateStamp(targetCost:tickets:)` with ticket path | ✅ |
| `getPropagationStamp(targetCost:)` | ✅ |
| `packedContainer()` / `writeToDirectory(_:)` / `unpackFromFile(_:)` | ✅ |
| `determineTransportEncryption()` / `determineCompressionSupport()` | ✅ |
| `asURI()` / `fromURI(_:)` | ✅ |
| Ticket constants: `ticketLength/Expiry/Grace/Renew/Interval`, `costTicket` | ✅ |
| Encryption description constants | ✅ |

### LXMRouter

| Feature | Status |
|---------|--------|
| `register(identity:transport:displayName:)` | ✅ |
| `send(_:)` — ticket wiring before pack + `includeTicket` handling | ✅ |
| `announce(destinationHash:attachedInterface:)` | ✅ |
| `getAnnounceAppData(destinationHash:)` | ✅ |
| `deliveryLinkAvailable(destinationHash:)` | ✅ |
| `getOutboundPropagationCost()` | ✅ |
| Auth API: `setAuthentication`, `allow`, `disallow`, `requiresAuthentication` | ✅ |
| Stamp API: `setInboundStampCost`, `getOutboundStampCost`, `setOutboundStampCost` | ✅ |
| Priority: `prioritise`, `unprioritise`, `isPrioritised` | ✅ |
| Stamp enforcement: `enforceStamps`, `ignoreStamps`, `isEnforcingStamps` | ✅ |
| Ignore list: `ignoreDestination`, `unignoreDestination`, `isIgnoringDestination` | ✅ |
| Ticket API: `rememberTicket`, `getOutboundTicket`, `getOutboundTicketExpiry`, | ✅ |
|            `generateTicket`, `getInboundTickets`, `cleanAvailableTickets` | ✅ |
| Message lifecycle: `hasMessage`, `cancelOutbound`, `getOutboundProgress` | ✅ |
| `requestMessagesFromPropagationNode`, `cancelPropagationNodeRequests` | ✅ |
| `ingestLXMURI(_:)` | ✅ |

### LXMF.swift

| Feature | Status |
|---------|--------|
| `Field` enum (0x01–0xFF) | ✅ |
| `AudioMode` enum (Codec2 + Opus modes) | ✅ |
| `RendererMode` enum (plain/micron/markdown/bbCode) | ✅ |
| `ReactionField`, `CommentField`, `ContinuationField` enums | ✅ |
| `SF_COMPRESSION`, `PN_META_*` constants | ✅ |
| `displayNameFromAppData`, `stampCostFromAppData`, `compressionSupportFromAppData` | ✅ |
| `pnNameFromAppData`, `pnStampCostFromAppData`, `propagationNodeAnnounceDataIsValid` | ✅ |

## Completed (Phase 18–19)

- Propagation node server (`enable_propagation`, `LXMPeer`, `sync_peers`, offer/get protocol) — +91 tests
- QR code delivery (`asQR()` → `CIImage` via `CIQRCodeGenerator`) — +12 tests

## Source Map (additions)

```
Sources/LXMF/
├── LXMPeer.swift       ← PropagationEntry, LXMPeerState, LXMPeerError, LXMSyncStrategy, LXMPeer
├── LXStamper.swift     ← + validatePeeringKey, validatePNStamp, validatePNStamps
└── Utilities/
    └── DataHex.swift   ← Data(hexString:) for message store indexing
```

## Conventions

- Depends on `ReticulumSwift` package (local path dependency)
- TDD: failing test → implement → green → commit; zero regressions tolerated
- `LXMessage` is a `final class` — all stored properties must be in the class body,
  not in `extension` blocks (Swift restriction)
- `LXMessage` uses `Data` for all byte fields; string convenience via `contentAsString`/`titleAsString`
- `LXMRouter` uses `NSLock` for thread safety; callers must not hold the lock when calling back
