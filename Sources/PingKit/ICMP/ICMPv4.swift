/// ICMPv4 echo message encoding and decoding. Pure functions with no I/O,
/// so the whole protocol layer is unit-testable in isolation.
public enum ICMPv4 {
    /// Size of the ICMP echo header (type, code, checksum, identifier, sequence).
    public static let headerSize = 8

    static let echoReplyType: UInt8 = 0
    static let destinationUnreachableType: UInt8 = 3
    static let echoRequestType: UInt8 = 8
    static let timeExceededType: UInt8 = 11

    /// RFC 1071 internet checksum over `bytes`, interpreted as big-endian
    /// 16-bit words. An odd trailing byte is padded with zero.
    ///
    /// A packet whose checksum field is already filled in sums to `0`.
    public static func internetChecksum(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var sum: UInt32 = 0
        var iterator = bytes.makeIterator()
        while let high = iterator.next() {
            let low = iterator.next() ?? 0
            sum &+= (UInt32(high) << 8) | UInt32(low)
        }
        while sum > 0xFFFF {
            sum = (sum & 0xFFFF) &+ (sum >> 16)
        }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    /// Builds a complete ICMP echo request datagram (header + payload) with
    /// the checksum filled in. Identifier and sequence are written in
    /// network byte order.
    public static func makeEchoRequest(identifier: UInt16, sequence: UInt16, payload: [UInt8]) -> [UInt8] {
        var packet = [UInt8]()
        packet.reserveCapacity(headerSize + payload.count)
        packet.append(echoRequestType)
        packet.append(0) // code
        packet.append(0) // checksum (placeholder)
        packet.append(0)
        packet.append(UInt8(identifier >> 8))
        packet.append(UInt8(identifier & 0xFF))
        packet.append(UInt8(sequence >> 8))
        packet.append(UInt8(sequence & 0xFF))
        packet.append(contentsOf: payload)
        let checksum = internetChecksum(packet)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xFF)
        return packet
    }

    /// Deterministic filler payload, mirroring the incrementing pattern
    /// classic `ping(8)` uses.
    public static func payloadPattern(size: Int) -> [UInt8] {
        precondition(size >= 0, "payload size must be non-negative")
        return (0..<size).map { UInt8(truncatingIfNeeded: $0) }
    }

    /// Parses an ICMP message (without any IP header). Bounds-checked
    /// throughout; malformed input throws rather than trapping.
    ///
    /// The checksum is only verified for echo messages. ICMP error messages
    /// (type 3/11) quote the original IP header, and the BSD/XNU kernel
    /// byte-swaps the quoted `ip_len` field in place before delivering the
    /// packet to sockets — so their checksum can never validate as received.
    /// Errors are instead authenticated by matching the quoted echo
    /// identifier/sequence against a pending probe.
    public static func parseMessage(_ bytes: ArraySlice<UInt8>, verifyChecksum: Bool = true) throws -> ICMPv4Message {
        guard bytes.count >= headerSize else { throw PacketParseError.truncated }
        let base = bytes.startIndex
        let type = bytes[base]
        let code = bytes[base + 1]
        if verifyChecksum, type == echoReplyType || type == echoRequestType {
            guard internetChecksum(bytes) == 0 else { throw PacketParseError.checksumMismatch }
        }

        func bigEndian16(at offset: Int) -> UInt16 {
            (UInt16(bytes[base + offset]) << 8) | UInt16(bytes[base + offset + 1])
        }

        switch type {
        case echoReplyType:
            return .echoReply(
                identifier: bigEndian16(at: 4),
                sequence: bigEndian16(at: 6),
                payloadCount: bytes.count - headerSize)
        case echoRequestType:
            return .echoRequest(identifier: bigEndian16(at: 4), sequence: bigEndian16(at: 6))
        case destinationUnreachableType:
            return .destinationUnreachable(code: code, probe: parseEmbeddedProbe(bytes[(base + headerSize)...]))
        case timeExceededType:
            return .timeExceeded(code: code, probe: parseEmbeddedProbe(bytes[(base + headerSize)...]))
        default:
            return .other(type: type, code: code)
        }
    }

    /// ICMP error messages embed the IP header plus at least 8 bytes of the
    /// original datagram. If that original datagram was one of our echo
    /// requests, extract its identifier/sequence so the error can be matched
    /// to a pending probe.
    static func parseEmbeddedProbe(_ bytes: ArraySlice<UInt8>) -> EmbeddedProbe? {
        guard let header = try? IPv4.parseHeader(bytes), header.protocolNumber == 1 else { return nil }
        let icmp = bytes[(bytes.startIndex + header.headerLength)...]
        guard icmp.count >= headerSize else { return nil }
        let base = icmp.startIndex
        guard icmp[base] == echoRequestType else { return nil }
        return EmbeddedProbe(
            identifier: (UInt16(icmp[base + 4]) << 8) | UInt16(icmp[base + 5]),
            sequence: (UInt16(icmp[base + 6]) << 8) | UInt16(icmp[base + 7]))
    }
}

/// A decoded ICMPv4 message, restricted to the kinds a ping client cares about.
public enum ICMPv4Message: Sendable, Equatable {
    case echoReply(identifier: UInt16, sequence: UInt16, payloadCount: Int)
    case echoRequest(identifier: UInt16, sequence: UInt16)
    case destinationUnreachable(code: UInt8, probe: EmbeddedProbe?)
    case timeExceeded(code: UInt8, probe: EmbeddedProbe?)
    case other(type: UInt8, code: UInt8)
}

/// Identifier/sequence of an echo request embedded inside an ICMP error message.
public struct EmbeddedProbe: Sendable, Equatable {
    public let identifier: UInt16
    public let sequence: UInt16

    public init(identifier: UInt16, sequence: UInt16) {
        self.identifier = identifier
        self.sequence = sequence
    }
}

/// Reasons a raw packet failed to parse.
public enum PacketParseError: Error, Sendable, Equatable {
    case truncated
    case invalidIPVersion(UInt8)
    case invalidHeaderLength(Int)
    case checksumMismatch
}
