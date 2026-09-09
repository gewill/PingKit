import Foundation
import Testing
@testable import PingKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A failed probe may be environmental, but unexpected syscall failures
/// must never turn the whole test run green by disabling integration tests.
enum LoopbackCapability: Sendable, Equatable {
    case available
    case failed(operation: String, errno: Int32)

    var available: Bool { self == .available }

    func requiresFailure(strict: Bool) -> Bool {
        guard case .failed(_, let code) = self else { return false }
        let environmental = [EACCES, EPERM, EAFNOSUPPORT, EPROTONOSUPPORT].contains(code)
        return strict || !environmental
    }
}

let icmpLoopbackAvailable = ipv4LoopbackCapability.available
let icmpv6LoopbackAvailable = ipv6LoopbackCapability.available
private let requireICMP = ProcessInfo.processInfo.environment["PINGKIT_REQUIRE_ICMP"] == "1"

let ipv4LoopbackCapability: LoopbackCapability = {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    #else
    let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_ICMP))
    #endif
    guard fd >= 0 else { return .failed(operation: "socket", errno: errno) }
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
    guard sent == probe.count else { return .failed(operation: "sendto", errno: errno) }
    return .available
}()

let ipv6LoopbackCapability: LoopbackCapability = {
    #if canImport(Darwin)
    let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
    #else
    let fd = socket(AF_INET6, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_ICMPV6))
    #endif
    guard fd >= 0 else { return .failed(operation: "socket", errno: errno) }
    defer { close(fd) }

    var address = sockaddr_in6()
    #if canImport(Darwin)
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    #endif
    address.sin6_family = sa_family_t(AF_INET6)
    withUnsafeMutableBytes(of: &address.sin6_addr) { bytes in
        bytes[15] = 1
    }
    let probe = ICMPv6.makeEchoRequest(identifier: 1, sequence: 0, payload: [])
    let sent = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            sendto(fd, probe, probe.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
    }
    guard sent == probe.count else { return .failed(operation: "sendto", errno: errno) }
    return .available
}()

@Suite struct LoopbackCapabilityTests {
    @Test func unexpectedProbeErrorsFailLocally() {
        #expect(!ipv4LoopbackCapability.requiresFailure(strict: false), "IPv4 probe: \(ipv4LoopbackCapability)")
        #expect(!ipv6LoopbackCapability.requiresFailure(strict: false), "IPv6 probe: \(ipv6LoopbackCapability)")
    }

    @Test(.enabled(if: requireICMP, "strict ICMP gate is enabled in official CI"))
    func ciRequiresBothLoopbacks() {
        #expect(ipv4LoopbackCapability == .available, "IPv4 probe: \(ipv4LoopbackCapability)")
        #expect(ipv6LoopbackCapability == .available, "IPv6 probe: \(ipv6LoopbackCapability)")
        print("PINGKIT_REQUIRE_ICMP=1: IPv4=\(ipv4LoopbackCapability), IPv6=\(ipv6LoopbackCapability)")
    }

    @Test(arguments: [EACCES, EPERM, EAFNOSUPPORT, EPROTONOSUPPORT, EBADF, EINVAL, ENOMEM])
    func classifiesProbeFailures(code: Int32) {
        let result = LoopbackCapability.failed(operation: "socket", errno: code)
        #expect(!result.available)
        #expect(result.requiresFailure(strict: true))
        let expected = [EBADF, EINVAL, ENOMEM].contains(code)
        #expect(result.requiresFailure(strict: false) == expected)
        #expect(!LoopbackCapability.available.requiresFailure(strict: true))
    }
}
