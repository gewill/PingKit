#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An IP address returned by a ping operation.
public enum IPAddress: Hashable, Sendable, CustomStringConvertible {
    case ipv4(IPv4Endpoint)
    case ipv6(IPv6Endpoint)

    public var description: String {
        switch self {
        case .ipv4(let endpoint): endpoint.description
        case .ipv6(let endpoint): endpoint.description
        }
    }
}

/// An IPv6 address and optional interface scope identifier.
public struct IPv6Endpoint: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]
    public let scopeID: UInt32

    public init?(bytes: [UInt8], scopeID: UInt32 = 0) {
        guard bytes.count == 16 else { return nil }
        self.bytes = bytes
        self.scopeID = scopeID
    }

    public var description: String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { destination in
            destination.copyBytes(from: bytes)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let text = withUnsafePointer(to: &address) { pointer in
            inet_ntop(AF_INET6, pointer, &buffer, socklen_t(buffer.count))
        }
        guard text != nil else { return "<invalid IPv6>" }
        let utf8 = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let addressText = String(decoding: utf8, as: UTF8.self)
        return scopeID == 0 ? addressText : "\(addressText)%\(scopeID)"
    }
}
