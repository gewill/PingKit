import Testing
@testable import PingKit

@Suite struct PacketParsingTests {
    @Test func echoRequestRoundTrip() throws {
        let packet = ICMPv4.makeEchoRequest(identifier: 0x1234, sequence: 7, payload: [1, 2, 3])
        let message = try ICMPv4.parseMessage(packet[...])
        #expect(message == .echoRequest(identifier: 0x1234, sequence: 7))
    }

    @Test func echoReplyParses() throws {
        let reply = Fixtures.echoReply(identifier: 0xABCD, sequence: 3, payload: ICMPv4.payloadPattern(size: 56))
        let message = try ICMPv4.parseMessage(reply[...])
        #expect(message == .echoReply(identifier: 0xABCD, sequence: 3, payloadCount: 56))
    }

    @Test func checksumMismatchRejected() {
        var reply = Fixtures.echoReply(identifier: 1, sequence: 1, payload: [])
        reply[2] ^= 0xFF
        #expect(throws: PacketParseError.checksumMismatch) {
            try ICMPv4.parseMessage(reply[...])
        }
    }

    @Test func truncatedMessageRejected() {
        #expect(throws: PacketParseError.truncated) {
            try ICMPv4.parseMessage([0, 0, 0][...])
        }
    }

    @Test func ipv4HeaderParses() throws {
        let datagram = Fixtures.ipv4Datagram(payload: [8, 0, 0, 0, 0, 0, 0, 0], ttl: 57, source: (10, 0, 0, 9))
        let header = try IPv4.parseHeader(datagram[...])
        #expect(header.headerLength == 20)
        #expect(header.timeToLive == 57)
        #expect(header.protocolNumber == 1)
        #expect(header.source == IPv4Endpoint(10, 0, 0, 9))
    }

    @Test func ipv4HeaderWithOptions() throws {
        let reply = Fixtures.echoReply(identifier: 5, sequence: 6, payload: [9])
        let datagram = Fixtures.ipv4Datagram(payload: reply, optionBytes: 8)
        let header = try IPv4.parseHeader(datagram[...])
        #expect(header.headerLength == 28)
        let parsed = ReceivedPacket.parse(datagram)
        #expect(parsed?.message == .echoReply(identifier: 5, sequence: 6, payloadCount: 1))
    }

    @Test func invalidIPVersionRejected() {
        var datagram = Fixtures.ipv4Datagram(payload: [])
        datagram[0] = 0x65
        #expect(throws: PacketParseError.invalidIPVersion(6)) {
            try IPv4.parseHeader(datagram[...])
        }
    }

    @Test func invalidHeaderLengthRejected() {
        var datagram = Fixtures.ipv4Datagram(payload: [0, 0, 0, 0, 0, 0, 0, 0])
        datagram[0] = 0x42 // IHL 2 → 8 bytes, below the 20-byte minimum
        #expect(throws: PacketParseError.invalidHeaderLength(8)) {
            try IPv4.parseHeader(datagram[...])
        }
    }

    @Test func receivedPacketWithIPHeader() {
        let reply = Fixtures.echoReply(identifier: 42, sequence: 0, payload: [])
        let datagram = Fixtures.ipv4Datagram(payload: reply, ttl: 63, source: (192, 168, 1, 1))
        let parsed = ReceivedPacket.parse(datagram)
        #expect(parsed?.message == .echoReply(identifier: 42, sequence: 0, payloadCount: 0))
        #expect(parsed?.timeToLive == 63)
        #expect(parsed?.source == IPv4Endpoint(192, 168, 1, 1))
    }

    @Test func receivedPacketWithoutIPHeader() {
        // Linux delivers bare ICMP messages; the heuristic must still parse them.
        let reply = Fixtures.echoReply(identifier: 42, sequence: 9, payload: [1])
        let parsed = ReceivedPacket.parse(reply)
        #expect(parsed?.message == .echoReply(identifier: 42, sequence: 9, payloadCount: 1))
        #expect(parsed?.timeToLive == nil)
        #expect(parsed?.source == nil)
    }

    @Test func malformedDatagramReturnsNil() {
        #expect(ReceivedPacket.parse([]) == nil)
        #expect(ReceivedPacket.parse([0x45]) == nil)
        #expect(ReceivedPacket.parse(Array(repeating: 0, count: 4)) == nil)
    }

    @Test func unreachableParsesAfterKernelByteSwap() {
        // XNU byte-swaps the quoted IP header's ip_len in place before
        // delivering ICMP errors, which invalidates the sender's checksum.
        // Error messages must still parse. (Observed live: a router's
        // "Destination Port Unreachable" for a fake-IP DNS target.)
        let request = ICMPv4.makeEchoRequest(identifier: 0xBEEF, sequence: 1, payload: ICMPv4.payloadPattern(size: 8))
        var datagram = Fixtures.unreachableDatagram(forRequest: request, code: 3)
        // The quoted IP header starts after outer IP (20) + outer ICMP (8).
        datagram.swapAt(30, 31) // swap the quoted ip_len bytes, as the kernel does
        let parsed = ReceivedPacket.parse(datagram)
        #expect(parsed?.message == .destinationUnreachable(
            code: 3,
            probe: EmbeddedProbe(identifier: 0xBEEF, sequence: 1)))
    }

    @Test func embeddedProbeExtractedFromUnreachable() throws {
        let request = ICMPv4.makeEchoRequest(identifier: 0x5555, sequence: 11, payload: ICMPv4.payloadPattern(size: 8))
        let datagram = Fixtures.unreachableDatagram(forRequest: request, code: 3)
        let parsed = ReceivedPacket.parse(datagram)
        #expect(parsed?.message == .destinationUnreachable(
            code: 3,
            probe: EmbeddedProbe(identifier: 0x5555, sequence: 11)))
    }
}
