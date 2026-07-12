import Testing
@testable import PingKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Probes whether this environment can actually create an unprivileged ICMP
/// socket and send to loopback. Sandboxed CI runners often can't; those get a
/// skip rather than a spurious failure.
let icmpLoopbackAvailable: Bool = {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    #else
    let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_ICMP))
    #endif
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: IPv4Endpoint(127, 0, 0, 1).rawAddress)
    let probe = ICMPv4.makeEchoRequest(identifier: 1, sequence: 0, payload: [])
    let sent = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            sendto(fd, probe, probe.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return sent == probe.count
}()

@Suite struct IntegrationTests {
    @Test(.enabled(if: icmpLoopbackAvailable, "ICMP datagram sockets are unavailable in this environment"))
    func oneShotPingLoopback() async throws {
        let reply = try await Pinger.ping("127.0.0.1", timeout: .seconds(2))
        #expect(reply.from == IPv4Endpoint(127, 0, 0, 1))
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
}
