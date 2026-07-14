#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum PingError: Error, Sendable, Equatable {
    case invalidConfiguration
    /// DNS resolution failed; `code` is the `getaddrinfo` error code.
    case resolutionFailed(host: String, code: Int32)
    case socketCreationFailed(errno: Int32)
    case socketOptionFailed(errno: Int32)
    case sendFailed(errno: Int32)
    /// A ping or traceroute sequence supports a single consumer. A second
    /// subscription (or reuse after a failed start) gets this error.
    case sequenceAlreadyConsumed
    case timedOut
    case destinationUnreachable(code: UInt8)
    case timeToLiveExceeded
    case packetTooBig(mtu: UInt32)
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
