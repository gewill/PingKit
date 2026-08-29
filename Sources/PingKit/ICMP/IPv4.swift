/// Minimal IPv4 header parsing — just enough to strip the header that Darwin
/// prepends to datagrams received on an ICMP datagram socket, and to read the
/// fields ping reports (TTL, source address).
public struct IPv4Header: Sendable, Equatable {
    /// Header length in bytes (IHL × 4), at least 20.
    public let headerLength: Int
    public let timeToLive: UInt8
    /// IP protocol number of the payload (1 = ICMP).
    public let protocolNumber: UInt8
    public let source: IPv4Endpoint
    public let destination: IPv4Endpoint
}

/// Namespace for the IPv4 header parsing entry points that produce an
/// ``IPv4Header``.
public enum IPv4 {
    /// Smallest legal IPv4 header, in bytes — a header with no options.
    public static let minimumHeaderLength = 20

    /// Parses an IPv4 header at the start of `bytes`. Bounds-checked; throws
    /// on truncated or malformed input.
    public static func parseHeader(_ bytes: ArraySlice<UInt8>) throws -> IPv4Header {
        guard bytes.count >= minimumHeaderLength else { throw PacketParseError.truncated }
        let base = bytes.startIndex
        let versionAndIHL = bytes[base]
        let version = versionAndIHL >> 4
        guard version == 4 else { throw PacketParseError.invalidIPVersion(version) }
        let headerLength = Int(versionAndIHL & 0x0F) * 4
        guard headerLength >= minimumHeaderLength else { throw PacketParseError.invalidHeaderLength(headerLength) }
        guard bytes.count >= headerLength else { throw PacketParseError.truncated }
        return IPv4Header(
            headerLength: headerLength,
            timeToLive: bytes[base + 8],
            protocolNumber: bytes[base + 9],
            source: IPv4Endpoint(bytes[base + 12], bytes[base + 13], bytes[base + 14], bytes[base + 15]),
            destination: IPv4Endpoint(bytes[base + 16], bytes[base + 17], bytes[base + 18], bytes[base + 19]))
    }
}
