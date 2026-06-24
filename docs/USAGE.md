# Using LXMFSwift

LXMFSwift gives you LXMF messaging on top of a running ReticulumSwift stack. This
guide covers the pieces beyond the [README](../README.md) quick start.

## The router

`LXMRouter` is the entry point. Construct it with your `Transport`, then
`register` one or more identities to get delivery destinations:

```swift
let router = LXMRouter(transport: stack.transport)
let address = try router.register(identity: identity, transport: stack.transport,
                                  displayName: "Alice")
router.onMessageReceived = { message in /* inbound */ }
```

To advertise that you're reachable, announce your delivery destination so peers
can find a path and your display name / stamp cost:

```swift
router.announce(destinationHash: address.hash)
```

## Delivery methods

`LXMessage.desiredMethod` selects how a message travels:

| Method | Behavior |
|--------|----------|
| `.opportunistic` | Single encrypted packet, no link. Best for short messages when a path is known. |
| `.direct` | Establish a Reticulum `Link` to the recipient and deliver reliably (supports larger payloads and attachments). |
| `.propagated` | Hand the message to a propagation node for store-and-forward; the recipient picks it up later. Requires an outbound propagation node. |

Leave `desiredMethod` unset to let the router choose based on reachability.

## Propagation nodes

To deliver while the recipient is offline, point the router at a propagation node
and send with `.propagated`. To fetch messages parked for you:

```swift
router.requestMessagesFromPropagationNode(identity)   // sync from your propagation node
```

LXMFSwift can also **be** a propagation node: enable propagation on the router so
it peers with other nodes and serves the offer/get sync protocol. See
`LXMPeer` and the propagation APIs on `LXMRouter`.

## Stamps and tickets

LXMF uses proof-of-work **stamps** to deter spam. A destination can advertise an
inbound stamp cost; senders must spend that cost (CPU work) unless they hold a
**ticket** — a token the recipient issued that lets a sender skip the PoW.

```swift
router.setInboundStampCost(8)              // require senders to spend cost 8
let ticket = router.generateTicket(forDestination: peerHash)  // issue a ticket
router.rememberTicket(ticket, forDestination: peerHash)        // store one you received
```

Enforcement is configurable (`enforceStamps()` / `ignoreStamps()`), as are
priority and ignore lists (`prioritise`, `ignoreDestination`, …).

## Messages on disk

`LXMessage` can be serialized to a packed container and restored:

```swift
let url = try message.writeToDirectory(messageStoreURL)
let restored = try LXMessage.unpackFromFile(url)
```

This is how a message store / inbox is persisted across launches.

## Fields and rich content

Beyond `content` and `title`, messages carry typed **fields** (the `Field` enum):
attachments, audio (Codec2 / Opus modes), images, renderer hints
(plain / Micron / Markdown / BBCode), reactions, and more. Set them via the
`fields: [Int: Any]` parameter on `LXMessage.init`.

## Interop

Messages produced by LXMFSwift are byte-compatible with Python LXMF, so they
interoperate with Sideband, NomadNet, and any LXMF node. For testing against a
Python node, see ReticulumSwift's
[INTEROP guide](https://github.com/SullivanPrell/ReticulumSwift/blob/main/docs/INTEROP.md).
