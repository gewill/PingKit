import Testing
@testable import PingKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite struct IntegrationTests {
    @Test(.enabled(if: icmpLoopbackAvailable, "ICMP datagram sockets are unavailable in this environment"))
    func oneShotPingLoopback() async throws {
        let reply = try await Pinger.ping("127.0.0.1", timeout: .seconds(2))
        #expect(reply.from == .ipv4(IPv4Endpoint(127, 0, 0, 1)))
        #expect(reply.roundTripTime > .zero)
        #expect(reply.byteCount == 64)
    }

    @Test(.enabled(if: icmpLoopbackAvailable, "ICMP datagram sockets are unavailable in this environment"))
    func continuousPingLoopback() async throws {
        let pinger = Pinger(
            host: "127.0.0.1",
            configuration: PingConfiguration(interval: .milliseconds(50), timeout: .seconds(2), count: .times(3)))
        var replies = 0
        for try await response in pinger.responses {
            if case .reply = response { replies += 1 }
        }
        #expect(replies == 3)
        let statistics = await pinger.statistics()
        #expect(statistics.transmitted == 3)
        #expect(statistics.received == 3)
    }

    @Test(.enabled(if: icmpv6LoopbackAvailable, "ICMPv6 datagram sockets are unavailable in this environment"))
    func oneShotIPv6PingLoopback() async throws {
        let reply = try await Pinger.ping(
            "::1",
            timeout: .seconds(2),
            addressFamily: .ipv6)
        let loopback = IPv6Endpoint(bytes: [UInt8](repeating: 0, count: 15) + [1])!
        #expect(reply.from == .ipv6(loopback))
        #expect(reply.timeToLive != nil)
        #expect(reply.roundTripTime > .zero)
        #expect(reply.byteCount == 64)
    }

    @Test(.enabled(if: icmpv6LoopbackAvailable, "ICMPv6 datagram sockets are unavailable in this environment"))
    func configuredIPv6HopLimit() async throws {
        let pinger = Pinger(
            host: "::1",
            configuration: PingConfiguration(
                timeout: .seconds(2),
                count: .times(1),
                timeToLive: 1,
                addressFamily: .ipv6))

        var replies = 0
        for try await response in pinger.responses {
            if case .reply = response { replies += 1 }
        }
        #expect(replies == 1)
    }

    @Test(.enabled(if: icmpLoopbackAvailable, "ICMP datagram sockets are unavailable in this environment"))
    func tracerouteLoopback() async throws {
        // Loopback is one hop away: TTL 1 must already reach the destination.
        let hops = try await Tracer.trace(
            "127.0.0.1",
            configuration: TracerouteConfiguration(maxHops: 3, probesPerHop: 1, timeout: .seconds(2)))
        #expect(hops.count == 1)
        #expect(hops[0].ttl == 1)
        #expect(hops[0].reachedDestination)
    }
}
