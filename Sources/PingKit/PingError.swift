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
    case sendFailed(errno: Int32)
    /// `Pinger.responses` supports a single consumer; a second subscription
    /// (or reuse after a failed start) gets this error. Create a new `Pinger`.
    case responsesAlreadyConsumed
    case timedOut
    case destinationUnreachable(code: UInt8)
    case timeToLiveExceeded
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
        case .sendFailed(let errorNumber):
            return "failed to send echo request: \(Self.describe(errno: errorNumber))"
        case .responsesAlreadyConsumed:
            return "Pinger.responses supports a single consumer; create a new Pinger instead"
        case .timedOut:
            return "request timed out"
        case .destinationUnreachable(let code):
            return "destination unreachable (ICMP code \(code))"
        case .timeToLiveExceeded:
            return "time to live exceeded in transit"
        }
    }

    private static func describe(errno errorNumber: Int32) -> String {
        "\(String(cString: strerror(errorNumber))) (errno \(errorNumber))"
    }
}
