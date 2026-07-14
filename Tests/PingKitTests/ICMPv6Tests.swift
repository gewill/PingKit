import Testing
@testable import PingKit

@Suite struct ICMPv6Tests {
    @Test func echoRequestEncoding() {
        let packet = ICMPv6.makeEchoRequest(
            identifier: 0x1234,
            sequence: 0x5678,
            payload: [0xAA, 0xBB])

        #expect(packet == [128, 0, 0, 0, 0x12, 0x34, 0x56, 0x78, 0xAA, 0xBB])
    }

    @Test func echoReplyParsing() throws {
        let message = try ICMPv6.parseMessage(
            [129, 0, 0xAB, 0xCD, 0x12, 0x34, 0x00, 0x02, 0xAA][...])

        #expect(message == .echoReply(identifier: 0x1234, sequence: 2, payloadCount: 1))
    }

    @Test func embeddedProbeParsingFromUnreachable() throws {
        let request = ICMPv6.makeEchoRequest(identifier: 0x1234, sequence: 7, payload: [])
        var invokingPacket = [UInt8](repeating: 0, count: 40)
        invokingPacket[0] = 0x60
        invokingPacket[6] = 58
        let message = try ICMPv6.parseMessage(
            ([1, 3, 0, 0, 0, 0, 0, 0] + invokingPacket + request)[...])

        #expect(message == .destinationUnreachable(
            code: 3,
            probe: EmbeddedProbe(identifier: 0x1234, sequence: 7)))
    }

    @Test func embeddedProbeRejectsNonICMPv6Packet() throws {
        var invokingPacket = [UInt8](repeating: 0, count: 40)
        invokingPacket[0] = 0x60
        invokingPacket[6] = 17
        let message = try ICMPv6.parseMessage(
            ([3, 0, 0, 0, 0, 0, 0, 0] + invokingPacket + [UInt8](repeating: 0, count: 8))[...])

        #expect(message == .timeExceeded(code: 0, probe: nil))
    }

    @Test func packetTooBigAndParameterProblemParsing() throws {
        let packetTooBig = try ICMPv6.parseMessage([2, 0, 0, 0, 0, 0, 5, 0][...])
        let parameterProblem = try ICMPv6.parseMessage([4, 1, 0, 0, 0, 0, 0, 40][...])

        #expect(packetTooBig == .packetTooBig(mtu: 1280, probe: nil))
        #expect(parameterProblem == .parameterProblem(code: 1, pointer: 40, probe: nil))
    }

    @Test func truncatedMessageRejected() {
        #expect(throws: PacketParseError.truncated) {
            try ICMPv6.parseMessage([129, 0, 0][...])
        }
    }
}

@Suite struct IPAddressTests {
    @Test func ipv6LoopbackDescription() {
        let endpoint = IPv6Endpoint(bytes: [UInt8](repeating: 0, count: 15) + [1])

        #expect(endpoint?.description == "::1")
        #expect(endpoint.map(IPAddress.ipv6)?.description == "::1")
    }

    @Test func ipv6ScopeIsPreserved() {
        let bytes: [UInt8] = [0xFE, 0x80] + [UInt8](repeating: 0, count: 14)
        let endpoint = IPv6Endpoint(bytes: bytes, scopeID: 4)

        #expect(endpoint?.scopeID == 4)
        #expect(endpoint?.description == "fe80::%4")
    }

    @Test func ipv6AddressRequiresSixteenBytes() {
        #expect(IPv6Endpoint(bytes: []) == nil)
        #expect(IPv6Endpoint(bytes: [UInt8](repeating: 0, count: 15)) == nil)
        #expect(IPv6Endpoint(bytes: [UInt8](repeating: 0, count: 17)) == nil)
    }
}

@Suite struct ResolverIPv6Tests {
    @Test func resolvesIPv6Literal() async throws {
        let endpoint = try await Resolver.resolve("::1", family: .ipv6)

        #expect(endpoint.address.description == "::1")
        guard case .ipv6 = endpoint else {
            Issue.record("expected IPv6 endpoint")
            return
        }
    }

    @Test func automaticResolutionSupportsBothLiteralFamilies() async throws {
        let ipv4 = try await Resolver.resolve("127.0.0.1", family: .automatic)
        let ipv6 = try await Resolver.resolve("::1", family: .automatic)

        #expect(ipv4.address == .ipv4(IPv4Endpoint(127, 0, 0, 1)))
        guard case .ipv6 = ipv6 else {
            Issue.record("expected IPv6 endpoint")
            return
        }
    }
}
