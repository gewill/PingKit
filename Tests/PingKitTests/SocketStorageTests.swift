import Testing
@testable import PingKit

@Suite struct SocketStorageTests {
    @Test(.enabled(if: icmpLoopbackAvailable, "IPv4 ICMP unavailable"))
    func compactIPv4Datagrams() async throws {
        try await verifyStorage(try ICMPv4Socket(destination: IPv4Endpoint(127, 0, 0, 1)), ipv6: false)
    }

    @Test(.enabled(if: icmpv6LoopbackAvailable, "IPv6 ICMP unavailable"))
    func compactIPv6Datagrams() async throws {
        let address = try #require(IPv6Endpoint(bytes: Array(repeating: 0, count: 15) + [1]))
        try await verifyStorage(try ICMPv6Socket(destination: address), ipv6: true)
    }

    private func verifyStorage(_ socket: any PingSocket, ipv6: Bool) async throws {
        defer { socket.close() }
        let (stream, continuation) = AsyncStream<SocketDatagram>.makeStream(bufferingPolicy: .bufferingOldest(16))
        try socket.activate { continuation.yield($0) }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(3))
            continuation.finish()
        }
        defer { watchdog.cancel(); continuation.finish() }
        let identifier = UInt16.random(in: 1 ... .max)
        let payload: [UInt8] = Array(repeating: 0xab, count: 17)
        let request = ipv6
            ? ICMPv6.makeEchoRequest(identifier: identifier, sequence: 77, payload: payload)
            : ICMPv4.makeEchoRequest(identifier: identifier, sequence: 77, payload: payload)
        try socket.send(request)
        var saved: SocketDatagram?
        for await datagram in stream {
            let sequence: UInt16
            let replyIdentifier: UInt16
            if ipv6 {
                guard case .echoReply(let id, let seq, _) = try? ICMPv6.parseMessage(datagram.bytes[...]) else { continue }
                replyIdentifier = id; sequence = seq
            } else {
                guard case .echoReply(let id, let seq, _) = ReceivedPacket.parse(datagram.bytes)?.message else { continue }
                replyIdentifier = id; sequence = seq
            }
            #if !os(Linux)
            guard replyIdentifier == identifier else { continue }
            #else
            _ = replyIdentifier
            #endif
            guard sequence == 77 else { continue }
            #expect(datagram.bytes.capacity < 1_024, "small replies must not retain a 64 KiB receive allocation")
            if let saved {
                // A second read reused the socket storage without altering
                // the datagram still owned by the first consumer.
                #expect(Array(saved.bytes.suffix(17)) == payload)
                #expect(Array(datagram.bytes.suffix(17)) == Array(repeating: 0xcd, count: 17))
                return
            }
            #expect(Array(datagram.bytes.suffix(17)) == payload)
            saved = datagram
            let nextPayload: [UInt8] = Array(repeating: 0xcd, count: 17)
            try socket.send(ipv6
                ? ICMPv6.makeEchoRequest(identifier: identifier, sequence: 77, payload: nextPayload)
                : ICMPv4.makeEchoRequest(identifier: identifier, sequence: 77, payload: nextPayload))
        }
        Issue.record("loopback did not return both replies")
    }
}
