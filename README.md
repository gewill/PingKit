# PingKit

[![CI](https://github.com/gewill/PingKit/actions/workflows/ci.yml/badge.svg)](https://github.com/gewill/PingKit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Modern ICMP ping library for Swift — IPv4 echo over unprivileged ICMP datagram
sockets (the same facility Apple's SimplePing uses), wrapped in a Swift 6
`actor` + `AsyncSequence` API. Zero dependencies.

Design rationale and roadmap live in [PLAN.md](PLAN.md).

## Requirements

- Swift 6.0+, macOS 13+ / iOS 16+ (Linux is best-effort; see below)
- No root or entitlement is needed on macOS command-line tools. Sandboxed Mac
  apps need `com.apple.security.network.client` and
  `com.apple.security.network.server`.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/gewill/PingKit.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyTarget", dependencies: [
        .product(name: "PingKit", package: "PingKit"),
    ]),
]
```

PingKit has no runtime dependencies (the only package dependency is the
DocC build plugin).

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
    payloadSize: 56))

for try await response in pinger.responses {
    switch response {
    case .reply(let r):                 print("seq=\(r.sequence) ttl=\(r.timeToLive ?? 0) rtt=\(r.roundTripTime)")
    case .timeout(let seq):             print("seq=\(seq) timed out")
    case .unreachable(let seq, let code): print("seq=\(seq) unreachable (code \(code))")
    case .timeExceeded(let seq):        print("seq=\(seq) TTL exceeded")
    }
}

let stats = await pinger.statistics()
print("\(stats.received)/\(stats.transmitted), loss \(stats.lossRate)")
```

Lifecycle rules:

- `responses` supports a **single consumer**; a second subscription throws
  `PingError.responsesAlreadyConsumed`. Create a new `Pinger` per run.
- Cancelling the consuming task stops the pinger and closes the socket.
- If you `break` out of the loop without cancelling, call `await pinger.stop()`
  (idempotent) to release the socket deterministically.

## CLI

```
swift run ping-cli 8.8.8.8 -c 5 -i 1 -W 2 -s 56
```

Prints `ping(8)`-style output including the closing statistics block; Ctrl-C
stops an unlimited run and still prints statistics.

## iOS notes

No entitlement is needed; unprivileged ICMP sockets work in the iOS app
sandbox (CI runs the full test suite, including loopback pings, on the iOS
Simulator). Two platform behaviors to plan for:

- **Local network privacy**: pinging LAN addresses triggers the iOS 14+
  local network permission prompt — add `NSLocalNetworkUsageDescription`
  to your Info.plist. Pinging internet hosts does not.
- **Suspension**: sockets don't receive while the app is suspended; an
  in-flight run resumes (with timeouts for missed probes) on return to
  foreground.

A minimal SwiftUI demo app for on-device testing lives in
[Examples/PingDemo](Examples/PingDemo).

## Linux notes

Unprivileged ICMP sockets require `net.ipv4.ping_group_range` to cover the
process's group (most distributions ship it disabled). The kernel also
rewrites the echo identifier on these sockets, so replies are matched by
sequence only there. CI builds and tests on Linux (including real loopback
pings inside a privileged container).
