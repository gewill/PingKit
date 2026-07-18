# PingKit Agent Instructions

## Project Overview

`PingKit` is a dependency-free Swift package that implements dual-stack ICMP
ping and IPv4 traceroute directly on unprivileged ICMP datagram sockets —
there is no vendored C engine and no root requirement. The public surface is
a Swift 6 `actor` + `AsyncSequence` API. Design rationale, platform pitfalls,
and the milestone roadmap live in `PLAN.md`.

The package contains three layers plus a demo:

- `Sources/PingKit/`: the library — `Pinger` and `Tracer` actors, ICMP
  encoding/parsing (`ICMP/`), socket wrappers (`Socket/`), resolver, and
  public models. This is the only product consumers link.
- `Sources/PingKitCLI/`: the `pingkit-cli` executable built on
  `swift-argument-parser`.
- `Tests/PingKitTests/` and `Tests/PingKitCLITests/`: unit, parsing, and
  loopback integration tests.
- `Examples/PingDemo/`: an Xcode demo app generated from `project.yml`
  (XcodeGen); it consumes the package as a local dependency.

## Dependencies

- Swift Package Manager is the package/build system; Swift 6.0+ toolchain,
  macOS 13+ / iOS 16+ deployment targets.
- The `PingKit` library target has **zero dependencies**. Keep it that way:
  `swift-argument-parser` is linked only into the `PingKitCLI` executable,
  and `swift-docc-plugin` is used only for documentation builds. Do not add
  a dependency to the library target.
- API documentation is a DocC catalog (`Sources/PingKit/PingKit.docc`);
  build it with `swift package generate-documentation --target PingKit`.

## Change Boundaries

- Keep public API changes in `Sources/PingKit/` and preserve the documented
  lifecycle semantics: `responses` is single-consumer (a second subscription
  throws `PingError.sequenceAlreadyConsumed`); each sequence number yields
  either `.sent` followed by exactly one terminal event, or a single
  `.sendFailed` with no `.sent`; `.sendFailed` is non-fatal and counts
  toward `transmitted`; cancellation and `stop()` are idempotent and release
  the socket and background send task.
- `PLAN.md` is the design document of record. When shipping a feature or
  changing direction, update its milestone sections rather than letting the
  plan drift from the code.
- README and `PLAN.md` reference the current release version (e.g. the
  installation snippet's `from: "…"`); bump them together when tagging a
  release.
- Product and scheme names are load-bearing: the executable is
  `pingkit-cli` (not `pingkit`) to avoid a case-insensitive collision with
  the library target, and `PingKit-LibraryTests` is the shared scheme that
  lets iOS test builds exclude the executable target. Renaming either breaks
  builds or CI.
- Regenerate `Examples/PingDemo` project changes through `project.yml`, not
  by hand-editing the generated Xcode project.
- Do not edit generated build output, `.build/`, or Xcode DerivedData.

## Behavior Verification

Before implementing, changing, testing, or documenting a feature, establish
what the correct behavior is — in this order:

1. **System CLI first.** Run the platform's `ping`, `ping6`, and `traceroute`
   with the relevant flags and observe the real output, for example
   `ping -c 3 127.0.0.1`, `ping6 -c 3 ::1`, or
   `traceroute -n -q 1 -m 4 1.1.1.1`. The library must match the CLI's
   observable semantics, not an assumption about them.
2. **OS socket semantics second.** PingKit sits directly on the kernel's
   unprivileged ICMP datagram sockets, so the mechanism layer is the
   platform, not project source. Confirm behavior against man pages, a small
   probe program, or kernel source (xnu, Linux `net/ipv4/ping.c`) — for
   example, macOS delivers the full IP header on IPv4 `SOCK_DGRAM` receives
   while ICMPv6 receives carry only the ICMPv6 message, and Linux ping
   sockets rewrite the echo identifier to the socket's bound port, so reply
   matching cannot assume the sent identifier comes back.
3. **RFC third.** When a wire format or protocol behavior has a formal
   definition, check the RFC and reflect that definition in documentation and
   tests: RFC 792 (ICMPv4), RFC 4443 (ICMPv6), RFC 1071 (internet checksum),
   RFC 3542 (IPv6 ancillary data API), RFC 6724 (address selection honored
   via `getaddrinfo` ordering). For example, traceroute depends on Time
   Exceeded messages as defined by RFC 792 / RFC 4443, and the checksum
   tests pin the RFC 1071 algorithm with known vectors.

Encode the verified behavior in tests: integration tests exercise real
loopback pings against the CLI's observable behavior, and unit tests pin
packet encoding, parsing, and matching semantics derived from the OS or the
RFC. Do not treat a surprising observation as a bug — and do not "fix" it —
before confirming it is not defined behavior.

## Testing

Use the smallest relevant check first, then the complete suite:

```sh
swift test                                   # macOS: includes loopback integration tests
xcodebuild -scheme PingKit -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
xcodebuild -scheme PingKit-LibraryTests -destination 'platform=iOS Simulator,name=<device>' test
```

Test-suite conventions (from `PLAN.md` §7):

- Protocol-layer pure functions get direct unit tests with golden fixtures
  captured from real packets (`Tests/PingKitTests/Fixtures.swift`).
- The socket layer is mocked through the internal `PingSocket` protocol to
  drive the state machine with injected replies, timeouts, and error
  messages.
- Integration tests ping `127.0.0.1` and `::1` only. They probe for
  unprivileged ICMP socket capability first and **skip** when it is absent —
  a permission problem must surface as a skip, never as a spurious failure
  or a spurious pass. External hosts are manual-only, never in CI.
- Lifecycle tests cover task cancellation, early loop exit, explicit
  `stop()`, double-close, and second-consumer rejection.

CI (`.github/workflows/ci.yml`) runs `swift test` on macOS (where the runner
allows unprivileged ICMP), an iOS device build plus simulator tests via the
`PingKit-LibraryTests` scheme, and a Linux matrix (Swift 6.0 and 6.1) in a
privileged container that enables `net.ipv4.ping_group_range` so the
integration tests run there too. Keep changes green on all three platforms;
Linux differences (identifier rewriting, no `SO_TIMESTAMP_MONOTONIC`) are
expected and handled in the socket layer, not by skipping Linux.
