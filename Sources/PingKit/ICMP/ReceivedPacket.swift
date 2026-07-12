/// A datagram received from an ICMP socket, decoded into an ICMP message plus
/// whatever IP-level metadata was available.
///
/// Darwin delivers ICMP datagram-socket reads with the full IPv4 header
/// prepended; Linux delivers the bare ICMP message. Rather than hard-coding
/// the platform, this sniffs the first byte: an IPv4 header starts with a
/// version nibble of 4 (0x45 for the common 20-byte header), while every ICMP
/// type a ping client cares about (0, 3, 8, 11) has a different high nibble.
public struct ReceivedPacket: Sendable {
    public let message: ICMPv4Message
    /// TTL from the IP header, when the header was present.
    public let timeToLive: UInt8?
    /// Source address from the IP header, when the header was present.
    public let source: IPv4Endpoint?

    /// Returns `nil` for anything malformed — stray packets on the socket
    /// must never crash or wedge the client.
    public static func parse(_ datagram: [UInt8]) -> ReceivedPacket? {
        guard !datagram.isEmpty else { return nil }
        if datagram[0] >> 4 == 4,
           let header = try? IPv4.parseHeader(datagram[...]),
           header.protocolNumber == 1 {
            guard let message = try? ICMPv4.parseMessage(datagram[header.headerLength...]) else { return nil }
            return ReceivedPacket(message: message, timeToLive: header.timeToLive, source: header.source)
        }
        guard let message = try? ICMPv4.parseMessage(datagram[...]) else { return nil }
        return ReceivedPacket(message: message, timeToLive: nil, source: nil)
    }
}
