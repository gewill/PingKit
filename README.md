# PingKit

[![CI](https://github.com/gewill/PingKit/actions/workflows/ci.yml/badge.svg)](https://github.com/gewill/PingKit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Modern dual-stack ICMP ping library for Swift — IPv4 and IPv6 echo over
unprivileged ICMP datagram sockets, wrapped in a Swift 6 `actor` +
`AsyncSequence` API. Zero dependencies.

On Apple platforms, RTTs are measured against the kernel's packet-arrival
timestamps (`SO_TIMESTAMP_MONOTONIC`), so scheduler wakeup latency doesn't
inflate them.

Design rationale and roadmap live in [PLAN.md](PLAN.md).

## Requirements

- Swift 6.0+, macOS 13+ / iOS 16+
- No root or entitlement is needed on macOS command-line tools. Sandboxed Mac
  apps need `com.apple.security.network.client` and
  `com.apple.security.network.server`.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/gewill/PingKit.git", from: "0.6.1"),
],
targets: [
    .target(name: "MyTarget", dependencies: [
        .product(name: "PingKit", package: "PingKit"),
    ]),
]
```

The `PingKit` library target has no runtime dependencies. The `pingkit`
executable uses Apple's `swift-argument-parser`; the DocC plugin is used only
for documentation builds.

The repository is currently private. Consumers need GitHub credentials with
repository access for Swift Package Manager to resolve this URL. Public Swift
Package Index distribution requires making the repository public first.

> **Stability**: 0.x releases follow SemVer, but the public API may still
> change between minor versions until 1.0.

API documentation is a DocC catalog; build it locally with
`swift package generate-documentation --target PingKit`.

## Usage

```swift
import PingKit

// One-shot
let reply = try await Pinger.ping("example.com")
print(reply.roundTripTime)

// Continuous
let pinger = Pinger(host: "1.1.1.1", configuration: .init(
    interval: .seconds(1),
    timeout: .seconds(2),
    count: .times(5),
    payloadSize: 56,
    timeToLive: nil,       // IPv4 TTL / IPv6 hop limit
    addressFamily: .automatic)) // follows system DNS ordering, including DNS64

for try await response in pinger.responses {
    switch response {
    case .sent(let seq):                print("seq=\(seq) sent")  // show a pending row here
    case .sendFailed(let seq, let err): print("seq=\(seq) send failed (errno \(err))")
    case .reply(let r):                 print("seq=\(r.sequence) ttl=\(r.timeToLive ?? 0) rtt=\(r.roundTripTime)")
    case .timeout(let seq):             print("seq=\(seq) timed out")
    case .unreachable(let seq, let code): print("seq=\(seq) unreachable (code \(code))")
    case .timeExceeded(let seq):        print("seq=\(seq) TTL exceeded")
    case .packetTooBig(let seq, let mtu): print("seq=\(seq) packet too big (MTU \(mtu))")
    case .parameterProblem(let seq, let code, let pointer):
        print("seq=\(seq) parameter problem (code \(code), pointer \(pointer))")
    }
}

let stats = await pinger.statistics()
print("\(stats.received)/\(stats.transmitted), loss \(stats.lossRate)")
```

Each sequence produces exactly one of two outcomes: a `.sent` followed by a
terminal event (the socket accepted the probe), or a single `.sendFailed`
with no `.sent` (the probe never left the socket — e.g. the network is
briefly unreachable). A `.sendFailed` does **not** end the run: the next
interval retries and recovers once the network does. A failed send still
counts toward `transmitted` (like `ping(8)`), so a network drop surfaces as
packet loss in `statistics()` rather than vanishing from the aggregate; the
`.sendFailed` event carries the `errno` for consumers that want to tell
"never sent" from "sent but lost". So a UI can insert a pending row on
`.sent` and update it in place, and render `.sendFailed` as a standalone
failed row. On stop, cancellation, or stream failure, consumers
should clear any remaining pending rows.

Lifecycle rules:

- `responses` supports a **single consumer**; a second subscription throws
  `PingError.sequenceAlreadyConsumed`. Create a new `Pinger` per run.
- Cancelling the consuming task stops the pinger and closes the socket.
- If you `break` out of the loop without cancelling, call `await pinger.stop()`
  (idempotent) to release the socket deterministically.

## IPv6 and NAT64

`addressFamily` defaults to `.automatic`. PingKit asks `getaddrinfo` for both
families and uses its first result, preserving the platform's RFC 6724 / DNS64
selection. This lets hostnames resolve to synthesized IPv6 destinations on an
IPv6-only NAT64 network. Use `.ipv4` or `.ipv6` to force a family; IPv6
literals and scoped link-local addresses are supported.

IPv6 replies expose their source through `IPAddress.ipv6` and their received
hop limit through `PingReply.timeToLive`. ICMPv6 Destination Unreachable,
Time Exceeded, Packet Too Big, and Parameter Problem messages map to typed
`PingResponse` events. `Tracer` remains IPv4-only in this release.

## Traceroute

`Tracer` sends echo requests with increasing TTL and reads the ICMP Time
Exceeded answers from intermediate routers — same unprivileged socket, no
root needed:

```swift
for try await hop in Tracer(host: "8.8.8.8").hops {
    print(hop.ttl, hop.probes)   // one TracerouteHop per TTL
}

// or collect the whole route at once
let route = try await Tracer.trace("8.8.8.8")
```

Each `TracerouteHop` groups the configurable per-TTL probes (default 3);
probes are `.response(router:roundTripTime:kind:)` or `.timeout`, and the
trace ends at the destination's echo reply, a Destination Unreachable, or
`maxHops`. `Tracer` follows the same lifecycle rules as `Pinger`.

Linux caveat: the kernel delivers ICMP errors to the socket error queue,
which PingKit doesn't read yet — intermediate hops show as timeouts there;
the destination hop still resolves.

## CLI

```
swift run pingkit-cli 8.8.8.8 -4 -c 5 -i 1 -W 2 -s 56 -m 64
swift run pingkit-cli ::1 -6 -c 3
swift run pingkit-cli trace 8.8.8.8 -m 30 -q 3 -W 1
```

The product is named `pingkit-cli` because a product named `pingkit` collides
with the `PingKit` library on case-insensitive file systems; the command
itself is `pingkit`, so install it as
`cp .build/release/pingkit-cli /usr/local/bin/pingkit`.

In ping mode `-4` / `-6` force the address family and `-m` sets the outgoing
TTL or hop limit; in trace mode `-m` sets the maximum hop count.

Prints `ping(8)`-style output including the closing statistics block
(`traceroute(8)`-style in trace mode); Ctrl-C stops an unlimited run and
still prints statistics.

## iOS notes

No entitlement is needed; unprivileged ICMP sockets work in the iOS app
sandbox (CI runs the full test suite, including loopback pings, on the iOS
Simulator). Two platform behaviors to plan for:

- **Local network privacy**: pinging LAN addresses triggers the iOS 14+
  local network permission prompt — add `NSLocalNetworkUsageDescription`
  to your Info.plist. Pinging internet hosts does not.
- **Backgrounding**: iOS makes no survival promise for suspended apps —
  on-device testing showed the process can be terminated within minutes of
  entering the background (and always is eventually). Don't expect a ping
  session to survive the background: stop the run when the scene leaves the
  foreground and start a new one on return (the demo app shows this
  `scenePhase` pattern). `Pinger.stop()`/deinit close the socket either way.

A minimal SwiftUI demo app for on-device testing lives in
[Examples/PingDemo](Examples/PingDemo).

## Linux notes

Unprivileged ICMP sockets require `net.ipv4.ping_group_range` to cover the
process's group (despite its name, it controls both IPv4 and IPv6 ping
sockets; most distributions ship it disabled). The kernel also
rewrites the echo identifier on these sockets, so replies are matched by
sequence only there. IPv4 and IPv6 echo build and test continuously on Linux,
including real loopback pings inside a privileged container. Traceroute is
IPv4-only and best-effort: intermediate hops require Linux error-queue support
that is not implemented yet; the destination reply still arrives.
