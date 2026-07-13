/// ICMPv6 echo encoding and message parsing as defined by RFC 4443.
public enum ICMPv6 {
    public static let headerSize = 8

    static let destinationUnreachableType: UInt8 = 1
    static let packetTooBigType: UInt8 = 2
    static let timeExceededType: UInt8 = 3
    static let parameterProblemType: UInt8 = 4
    static let echoRequestType: UInt8 = 128
    static let echoReplyType: UInt8 = 129

    /// Builds an ICMPv6 Echo Request. The checksum remains zero because an
    /// ICMPv6 datagram socket supplies the IPv6 pseudo-header and computes it.
    public static func makeEchoRequest(identifier: UInt16, sequence: UInt16, payload: [UInt8]) -> [UInt8] {
        [
            echoRequestType, 0, 0, 0,
            UInt8(identifier >> 8), UInt8(identifier & 0xFF),
            UInt8(sequence >> 8), UInt8(sequence & 0xFF),
        ] + payload
    }

    /// Parses a bare ICMPv6 message. Checksum validation is delegated to the
    /// kernel because it requires the IPv6 pseudo-header.
    public static func parseMessage(_ bytes: ArraySlice<UInt8>) throws -> ICMPv6Message {
        guard bytes.count >= headerSize else { throw PacketParseError.truncated }
        let base = bytes.startIndex
        let type = bytes[base]
        let code = bytes[base + 1]

        func bigEndian16(at offset: Int) -> UInt16 {
            (UInt16(bytes[base + offset]) << 8) | UInt16(bytes[base + offset + 1])
        }

        func bigEndian32(at offset: Int) -> UInt32 {
            (UInt32(bytes[base + offset]) << 24)
                | (UInt32(bytes[base + offset + 1]) << 16)
                | (UInt32(bytes[base + offset + 2]) << 8)
                | UInt32(bytes[base + offset + 3])
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
        case packetTooBigType:
            return .packetTooBig(mtu: bigEndian32(at: 4), probe: parseEmbeddedProbe(bytes[(base + headerSize)...]))
        case timeExceededType:
            return .timeExceeded(code: code, probe: parseEmbeddedProbe(bytes[(base + headerSize)...]))
        case parameterProblemType:
            return .parameterProblem(
                code: code,
                pointer: bigEndian32(at: 4),
                probe: parseEmbeddedProbe(bytes[(base + headerSize)...]))
        default:
            return .other(type: type, code: code)
        }
    }

    /// Our outgoing packets have no IPv6 extension headers, so a quoted
    /// packet must contain the 40-byte IPv6 base header followed by ICMPv6.
    static func parseEmbeddedProbe(_ bytes: ArraySlice<UInt8>) -> EmbeddedProbe? {
        guard bytes.count >= 40 + headerSize else { return nil }
        let base = bytes.startIndex
        guard bytes[base] >> 4 == 6, bytes[base + 6] == 58 else { return nil }
        let icmp = bytes[(base + 40)...]
        guard icmp[icmp.startIndex] == echoRequestType else { return nil }
        let messageBase = icmp.startIndex
        return EmbeddedProbe(
            identifier: (UInt16(icmp[messageBase + 4]) << 8) | UInt16(icmp[messageBase + 5]),
            sequence: (UInt16(icmp[messageBase + 6]) << 8) | UInt16(icmp[messageBase + 7]))
    }
}

/// A decoded ICMPv6 message relevant to ping.
public enum ICMPv6Message: Sendable, Equatable {
    case echoReply(identifier: UInt16, sequence: UInt16, payloadCount: Int)
    case echoRequest(identifier: UInt16, sequence: UInt16)
    case destinationUnreachable(code: UInt8, probe: EmbeddedProbe?)
    case packetTooBig(mtu: UInt32, probe: EmbeddedProbe?)
    case timeExceeded(code: UInt8, probe: EmbeddedProbe?)
    case parameterProblem(code: UInt8, pointer: UInt32, probe: EmbeddedProbe?)
    case other(type: UInt8, code: UInt8)
}
