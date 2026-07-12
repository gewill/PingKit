# PingKit

Modern ICMP ping library for Swift — IPv4 echo over unprivileged ICMP datagram
sockets (the same facility Apple's SimplePing uses), wrapped in a Swift 6
`actor` + `AsyncSequence` API. Zero dependencies.

Design rationale and roadmap live in [PLAN.md](PLAN.md).

## Requirements

- Swift 6.0+, macOS 13+ / iOS 16+ (Linux is best-effort; see below)
- No root or entitlement is needed on macOS command-line tools. Sandboxed Mac
  apps need `com.apple.security.network.client` and
  `com.apple.security.network.server`.

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

## Linux notes

Unprivileged ICMP sockets require `net.ipv4.ping_group_range` to cover the
process's group (most distributions ship it disabled). The kernel also
rewrites the echo identifier on these sockets, so replies are matched by
sequence only there. Linux is compiled for but not yet CI-verified.
