# Platform Notes

Address family selection, the Apple-platform permissions and lifecycle to
plan for, and the Linux kernel settings PingKit depends on.

## Overview

PingKit sits directly on the kernel's unprivileged ICMP datagram sockets, so
what you observe is the platform's behavior rather than a library policy laid
over it. The differences below are the ones that change how you write against
the API.

## Address Families and NAT64

``PingConfiguration/addressFamily`` defaults to `.automatic`. PingKit asks
`getaddrinfo` for both families and uses its first result, preserving the
platform's RFC 6724 / DNS64 selection. This lets hostnames resolve to
synthesized IPv6 destinations on an IPv6-only NAT64 network. Use `.ipv4` or
`.ipv6` to force a family; IPv6 literals and scoped link-local addresses are
supported.

IPv6 replies expose their source through ``IPAddress`` and their received hop
limit through ``PingReply/timeToLive``. ICMPv6 Destination Unreachable, Time
Exceeded, Packet Too Big, and Parameter Problem messages map to typed
``PingResponse`` events. ``Tracer`` remains IPv4-only in this release.

## Apple Platforms

No entitlement is needed on iOS — unprivileged ICMP sockets work inside the
app sandbox, and CI runs the full test suite, loopback pings included, on the
iOS Simulator. Sandboxed Mac apps need `com.apple.security.network.client`
and `com.apple.security.network.server`.

### Local network privacy

Pinging LAN addresses triggers the iOS 14+ local network permission prompt —
add `NSLocalNetworkUsageDescription` to your Info.plist. Pinging internet
hosts does not.

### Backgrounding

iOS makes no survival promise for suspended apps: on-device testing showed
the process can be terminated within minutes of entering the background, and
always is eventually. Do not expect a ping session to survive the background.
Stop the run when the scene leaves the foreground and start a new one on
return. ``Pinger/stop()`` and `deinit` close the socket either way.

The `Examples/PingDemo` app in the repository shows this `scenePhase`
pattern, and is where permission, NAT64, and backgrounding behavior can be
verified on a real device.

## Linux

Unprivileged ICMP sockets require `net.ipv4.ping_group_range` to cover the
process's group. Despite its name it controls both IPv4 and IPv6 ping
sockets, and most distributions ship it disabled.

The kernel also rewrites the echo identifier on these sockets, so replies are
matched by sequence only there.

IPv4 and IPv6 echo build and test continuously on Linux, including real
loopback pings inside a privileged container. Traceroute is IPv4-only and
best-effort: intermediate hops require Linux error-queue support that is not
implemented yet, so they show as timeouts; the destination reply still
arrives.
