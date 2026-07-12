import Testing
@testable import PingKit

@Suite struct ChecksumTests {
    @Test func rfc1071Vector() {
        // Words 0x0001 + 0xf203 + 0xf4f5 + 0xf6f7 with end-around carry
        // sum to 0xddf2; the checksum is its one's complement.
        let bytes: [UInt8] = [0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]
        #expect(ICMPv4.internetChecksum(bytes) == 0x220d)
    }

    @Test func oddLengthPadsWithZero() {
        #expect(ICMPv4.internetChecksum([0x01]) == 0xFEFF)
    }

    @Test func emptyInput() {
        #expect(ICMPv4.internetChecksum([]) == 0xFFFF)
    }

    @Test func builtRequestVerifiesToZero() {
        let packet = ICMPv4.makeEchoRequest(
            identifier: 0xBEEF,
            sequence: 42,
            payload: ICMPv4.payloadPattern(size: 56))
        #expect(ICMPv4.internetChecksum(packet) == 0)
    }
}
