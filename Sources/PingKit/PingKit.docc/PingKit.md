# ``PingKit``

Modern ICMP ping for Swift: IPv4 echo over unprivileged ICMP datagram
sockets, exposed as a Swift 6 `actor` with an `AsyncSequence` API.

## Overview

PingKit sends ICMP echo requests without root privileges or special
entitlements, using the same kernel facility as Apple's SimplePing sample
(`SOCK_DGRAM` + `IPPROTO_ICMP`). It has no runtime dependencies.

```swift
// One-shot
let reply = try await Pinger.ping("example.com")

// Continuous
let pinger = Pinger(host: "1.1.1.1", configuration: .init(count: .times(5)))
for try await response in pinger.responses {
    switch response {
    case .reply(let r):
        print("seq=\(r.sequence) rtt=\(r.roundTripTime)")
    case .timeout(let seq):
        print("seq=\(seq) timed out")
    case .unreachable(let seq, let code):
        print("seq=\(seq) unreachable, code \(code)")
    case .timeExceeded(let seq):
        print("seq=\(seq) TTL exceeded")
    }
}
let stats = await pinger.statistics()
```

A ``Pinger`` runs once: ``Pinger/responses`` supports a single consumer, and
cancelling the consuming task (or calling ``Pinger/stop()``) tears down the
socket deterministically.

## Topics

### Essentials

- ``Pinger``
- ``PingConfiguration``
- ``PingResponses``

### Results

- ``PingResponse``
- ``PingReply``
- ``PingStatistics``
- ``PingError``

### Traceroute

- ``Tracer``
- ``TracerouteConfiguration``
- ``TracerouteHops``
- ``TracerouteHop``
- ``TracerouteProbe``

### Addressing

- ``IPv4Endpoint``

### Protocol Layer

The wire-format layer is pure functions, exposed for reuse and testing.

- ``ICMPv4``
- ``ICMPv4Message``
- ``EmbeddedProbe``
- ``IPv4``
- ``IPv4Header``
- ``ReceivedPacket``
- ``PacketParseError``

### Socket Abstraction

- ``PingSocket``
