# Getting Started

Add the package, send one echo request, then consume a continuous run.

## Add the Package

```swift
dependencies: [
    .package(url: "https://github.com/gewill/PingKit.git", from: "0.6.1"),
],
targets: [
    .target(name: "MyTarget", dependencies: ["PingKit"]),
]
```

No entitlement and no root privilege are required — PingKit sends over
unprivileged ICMP datagram sockets. Sandboxed Mac apps still need
`com.apple.security.network.client` and `com.apple.security.network.server`.

## Ping Once

``Pinger/ping(_:timeout:payloadSize:addressFamily:)`` sends a single echo
request and returns the matched reply. It throws rather than reporting an
event: a timeout becomes ``PingError/timedOut``, and an ICMP error becomes
the matching ``PingError`` case.

```swift
import PingKit

let reply = try await Pinger.ping("example.com")
print("\(reply.byteCount) bytes from \(reply.from): time=\(reply.roundTripTime)")
```

## Ping Continuously

Create a ``Pinger`` and iterate ``Pinger/responses``. Each event carries the
sequence number it belongs to, so a UI can show one row per probe and update
it in place.

```swift
let pinger = Pinger(
    host: "1.1.1.1",
    configuration: PingConfiguration(interval: .seconds(1), count: .times(5)))

for try await response in pinger.responses {
    switch response {
    case .sent(let sequence):
        print("seq=\(sequence) sent")
    case .reply(let reply):
        print("seq=\(reply.sequence) rtt=\(reply.roundTripTime) from \(reply.from)")
    case .timeout(let sequence):
        print("seq=\(sequence) timed out")
    case .sendFailed(let sequence, let code):
        print("seq=\(sequence) never left the socket, errno \(code)")
    case .unreachable, .timeExceeded, .packetTooBig, .parameterProblem:
        print("ICMP error: \(response)")
    }
}
```

### What one sequence number produces

Every sequence number yields exactly one of two shapes:

- ``PingResponse/sent(sequence:)`` followed by exactly one terminal event —
  the socket accepted the probe.
- a single ``PingResponse/sendFailed(sequence:errno:)`` with no `.sent` — the
  probe never left the host.

A send failure is **not** fatal. The run continues and recovers on a later
interval once the network comes back. It still counts toward
``PingStatistics/transmitted``, matching `ping(8)`, so it surfaces as loss
rather than disappearing from the accounting.

## Configure the Run

``PingConfiguration`` carries the knobs; every one has a default.

```swift
PingConfiguration(
    interval: .seconds(1),       // delay between probes
    timeout: .seconds(2),        // per-probe reply deadline
    count: .times(5),            // or .unlimited
    payloadSize: 56,             // classic default: 64-byte ICMP messages
    timeToLive: 64,              // nil keeps the system default
    addressFamily: .automatic)   // or .ipv4 / .ipv6
```

`.automatic` follows `getaddrinfo` ordering, so a hostname resolves the way
the rest of the system resolves it. An invalid combination throws
``PingError/invalidConfiguration`` when the run starts.

## Lifecycle

Resolution and socket setup happen lazily on the first iteration, so
configuration, DNS, and socket errors surface from the first `next()` rather
than from the initializer.

- ``Pinger/responses`` supports a **single consumer**. A second subscription
  throws ``PingError/sequenceAlreadyConsumed``.
- Cancelling the consuming task stops sending, closes the socket, and ends
  the sequence.
- Breaking out of the loop without cancelling does not stop the pinger in
  every case — call ``Pinger/stop()`` when you finish early. It is
  idempotent and safe to call from anywhere.

```swift
let task = Task {
    for try await response in pinger.responses {
        // …
    }
}

task.cancel()          // ends the run, or
await pinger.stop()    // stop it explicitly
```

## Read the Statistics

``Pinger/statistics()`` is a snapshot of the run so far, in the shape
`ping(8)` prints at exit. Read it at any time, not only after the sequence
finishes.

```swift
let stats = await pinger.statistics()
print("\(stats.transmitted) transmitted, \(stats.received) received, "
    + "\(stats.lossRate * 100)% loss")
print("min/avg/max = \(stats.minRTT)/\(stats.averageRTT)/\(stats.maxRTT)")
```

## Trace a Route

``Tracer`` follows the same lifecycle contract as ``Pinger`` — one run, a
single consumer, idempotent ``Tracer/stop()`` — and yields one
``TracerouteHop`` per TTL.

```swift
let tracer = Tracer(host: "example.com")
for try await hop in tracer.hops {
    print(hop.ttl, hop.probes)
}
```

Traceroute is IPv4 only.

## Topics

### Next Steps

- ``Pinger``
- ``PingConfiguration``
- ``PingResponse``
- ``Tracer``
