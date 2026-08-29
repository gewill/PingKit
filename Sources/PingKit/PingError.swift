#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Errors thrown by a ping or traceroute run.
///
/// Setup failures — configuration, resolution, socket creation and options,
/// and a rejected second consumer — surface here for every run. Per-probe
/// network outcomes do not: a continuous run reports those as
/// ``PingResponse`` events, and only the one-shot
/// ``Pinger/ping(_:timeout:payloadSize:addressFamily:)`` converts them into
/// the matching case below.
public enum PingError: Error, Sendable, Equatable {
    /// The configuration failed validation as the run started: a
    /// non-positive interval or timeout, a payload outside `0...65507`, a
    /// `.times(n)` count below 1, a TTL outside `1...255`, or — for a trace
    /// — `maxHops` outside `1...255` or `probesPerHop` outside `1...16`.
    case invalidConfiguration
    /// DNS resolution failed; `code` is the `getaddrinfo` error code.
    case resolutionFailed(host: String, code: Int32)
    /// The ICMP datagram socket could not be opened; `errno` carries the
    /// system's reason. Platforms gate unprivileged ICMP sockets
    /// differently — see <doc:PlatformNotes>.
    case socketCreationFailed(errno: Int32)
    /// A required socket option was rejected: the IPv6 receive-hop-limit
    /// option at setup, or the outgoing TTL / hop limit before a probe.
    /// `errno` carries the system's reason. Options the implementation
    /// treats as best-effort — kernel receive timestamps, the ICMPv6 type
    /// filter — never produce this.
    case socketOptionFailed(errno: Int32)
    /// The probe never left the socket. Thrown only by the one-shot
    /// ``Pinger/ping(_:timeout:payloadSize:addressFamily:)``; a continuous
    /// run reports ``PingResponse/sendFailed(sequence:errno:)`` and keeps
    /// going.
    case sendFailed(errno: Int32)
    /// A ping or traceroute sequence supports a single consumer. A second
    /// subscription (or reuse after a failed start) gets this error.
    case sequenceAlreadyConsumed
    /// No reply arrived within the configured timeout. One-shot only; a
    /// continuous run yields ``PingResponse/timeout(sequence:)``.
    case timedOut
    /// The network answered Destination Unreachable. One-shot only; a
    /// continuous run yields ``PingResponse/unreachable(sequence:code:)``.
    /// ICMPv4 and ICMPv6 number their codes differently — read `code`
    /// according to the family the run resolved to.
    case destinationUnreachable(code: UInt8)
    /// The probe's TTL or hop limit ran out before reaching the host.
    /// One-shot only; a continuous run yields
    /// ``PingResponse/timeExceeded(sequence:)``.
    case timeToLiveExceeded
    /// IPv6 path MTU discovery reported the probe too large for the next
    /// hop; `mtu` is the limit it reported. One-shot only; a continuous run
    /// yields ``PingResponse/packetTooBig(sequence:mtu:)``.
    case packetTooBig(mtu: UInt32)
    /// IPv6 reported an invalid field in the probe; `pointer` is the byte
    /// offset it objected to. One-shot only; a continuous run yields
    /// ``PingResponse/parameterProblem(sequence:code:pointer:)``.
    case parameterProblem(code: UInt8, pointer: UInt32)
}

extension PingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidConfiguration:
            return "invalid ping configuration"
        case .resolutionFailed(let host, let code):
            return "cannot resolve \(host): \(String(cString: gai_strerror(code)))"
        case .socketCreationFailed(let errorNumber):
            var message = "failed to create ICMP socket: \(Self.describe(errno: errorNumber))"
            if errorNumber == EACCES || errorNumber == EPERM {
                message += " (on Linux, unprivileged ICMP requires net.ipv4.ping_group_range to cover this process's group, or CAP_NET_RAW)"
            }
            return message
        case .socketOptionFailed(let errorNumber):
            return "failed to set socket option: \(Self.describe(errno: errorNumber))"
        case .sendFailed(let errorNumber):
            return "failed to send echo request: \(Self.describe(errno: errorNumber))"
        case .sequenceAlreadyConsumed:
            return "this ping or traceroute sequence already has a consumer; create a new instance instead"
        case .timedOut:
            return "request timed out"
        case .destinationUnreachable(let code):
            return "destination unreachable (ICMP code \(code))"
        case .timeToLiveExceeded:
            return "time to live exceeded in transit"
        case .packetTooBig(let mtu):
            return "packet too big for IPv6 path (MTU \(mtu))"
        case .parameterProblem(let code, let pointer):
            return "IPv6 parameter problem (code \(code), pointer \(pointer))"
        }
    }

    private static func describe(errno errorNumber: Int32) -> String {
        "\(String(cString: strerror(errorNumber))) (errno \(errorNumber))"
    }
}
