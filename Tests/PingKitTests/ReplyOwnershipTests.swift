import Testing
@testable import PingKit

@Suite struct ReplyOwnershipTests {
    @Test(arguments: [false, true])
    func multicastKeepsFirstMemberReply(ipv6: Bool) async throws {
        let target: ResolvedEndpoint = ipv6
            ? .ipv6(IPv6Endpoint(bytes: [0xff, 0x02] + Array(repeating: 0, count: 13) + [1], scopeID: 4)!)
            : .ipv4(IPv4Endpoint(224, 0, 0, 1))
        let source: IPAddress = ipv6
            ? .ipv6(IPv6Endpoint(bytes: [0xfe, 0x80] + Array(repeating: 0, count: 13) + [2], scopeID: 4)!)
            : .ipv4(IPv4Endpoint(127, 0, 0, 1))
        let socket = MockPingSocket(autoDatagram: { request in
            var bytes = ipv6 ? request : Fixtures.replyDatagram(forRequest: request)
            if ipv6 { bytes[0] = 129 }
            return SocketDatagram(bytes: bytes, receivedAt: .now(), source: source)
        })
        let pinger = Pinger(
            host: "test.invalid", configuration: .init(count: .times(1)),
            socketFactory: { _ in socket }, resolver: { _ in target })
        for try await event in pinger.responses {
            if case .reply(let reply) = event { #expect(reply.from == source) }
        }
        #expect(await pinger.statistics().received == 1)
    }

    @Test(arguments: [false, true])
    func ipv4RejectsForeignReply(withIPHeader: Bool) async throws {
        let socket = MockPingSocket(datagramsForIndex: { _, request in
            let id = UInt16(request[4]) << 8 | UInt16(request[5])
            let seq = UInt16(request[6]) << 8 | UInt16(request[7])
            let wrong = Fixtures.echoReply(identifier: id, sequence: seq, payload: [])
            let good = Fixtures.replyDatagram(forRequest: request)
            return [
                SocketDatagram(
                    bytes: withIPHeader ? Fixtures.ipv4Datagram(payload: wrong, source: (192, 0, 2, 1)) : wrong,
                    receivedAt: .now(), source: .ipv4(IPv4Endpoint(192, 0, 2, 1))),
                SocketDatagram(
                    bytes: withIPHeader ? good : Array(good.dropFirst(20)),
                    receivedAt: .now(), source: .ipv4(IPv4Endpoint(127, 0, 0, 1))),
            ]
        })
        let pinger = makePinger(configuration: .init(count: .times(1)), socket: socket)
        var events: [PingResponse] = []
        for try await event in pinger.responses { events.append(event) }
        guard case .reply(let reply)? = events.last else {
            Issue.record("valid reply should complete the probe")
            return
        }
        #expect(reply.from == .ipv4(IPv4Endpoint(127, 0, 0, 1)))
        #expect(reply.byteCount == 64)
    }

    @Test(arguments: [false, true])
    func ipv4ErrorMustQuoteOurDestination(trace: Bool) async throws {
        let socket = MockPingSocket(repliesForIndex: { _, request in
            var wrong = Fixtures.unreachableDatagram(forRequest: request)
            // Outer IPv4 + ICMP error + quoted IPv4 destination.
            wrong[44] = 192; wrong[45] = 0; wrong[46] = 2; wrong[47] = 1
            return [wrong, Fixtures.replyDatagram(forRequest: request)]
        })
        if trace {
            let tracer = Tracer(
                host: "test.invalid", configuration: .init(maxHops: 1, probesPerHop: 1),
                socketFactory: { _ in socket }, resolver: { _ in IPv4Endpoint(127, 0, 0, 1) })
            for try await hop in tracer.hops { #expect(hop.reachedDestination) }
        } else {
            let pinger = makePinger(configuration: .init(count: .times(1)), socket: socket)
            for try await event in pinger.responses {
                if case .sent = event { continue }
                if case .reply = event { continue }
                Issue.record("foreign quoted destination was accepted: \(event)")
            }
        }
    }

    @Test func tracerRejectsForeignEchoReply() async throws {
        let socket = MockPingSocket(repliesForIndex: { _, request in
            var wrong = Fixtures.replyDatagram(forRequest: request)
            wrong[12] = 192; wrong[13] = 0; wrong[14] = 2; wrong[15] = 1
            return [wrong, Fixtures.replyDatagram(forRequest: request)]
        })
        let tracer = Tracer(
            host: "test.invalid", configuration: .init(maxHops: 1, probesPerHop: 1),
            socketFactory: { _ in socket }, resolver: { _ in IPv4Endpoint(127, 0, 0, 1) })
        for try await hop in tracer.hops {
            guard case .response(let router, _, .destination)? = hop.probes.first else {
                Issue.record("expected destination reply")
                return
            }
            #expect(router == IPv4Endpoint(127, 0, 0, 1))
        }
    }

    @Test(arguments: [0, 1, 2])
    func ipv6RejectsForeignOrMissingSource(kind: Int) async throws {
        let target = IPv6Endpoint(bytes: [0xfe, 0x80] + Array(repeating: 0, count: 13) + [1], scopeID: 4)!
        let socket = MockPingSocket(datagramsForIndex: { _, request in
            var good = request
            good[0] = 129
            let source: IPAddress?
            switch kind {
            case 0: source = nil
            case 1:
                var bytes = target.bytes
                bytes[15] = 2
                source = .ipv6(IPv6Endpoint(bytes: bytes, scopeID: 4)!)
            default: source = .ipv6(IPv6Endpoint(bytes: target.bytes, scopeID: 5)!)
            }
            return [
                SocketDatagram(bytes: Array(good.prefix(8)), receivedAt: .now(), source: source),
                SocketDatagram(bytes: good, receivedAt: .now(), source: .ipv6(target)),
            ]
        })
        let pinger = Pinger(
            host: "test.invalid", configuration: .init(count: .times(1), addressFamily: .ipv6),
            socketFactory: { _ in socket }, resolver: { _ in .ipv6(target) })
        for try await event in pinger.responses {
            if case .reply(let reply) = event {
                #expect(reply.from == .ipv6(target))
                #expect(reply.byteCount == 64)
            }
        }
        #expect(await pinger.statistics().received == 1)
    }

    @Test func ipv6ErrorMustQuoteOurDestination() async throws {
        let target = IPv6Endpoint(bytes: Array(repeating: 0, count: 15) + [1])!
        let socket = MockPingSocket(datagramsForIndex: { _, request in
            var header = Array<UInt8>(repeating: 0, count: 40)
            header[0] = 0x60; header[6] = 58; header[39] = 2
            var reply = request
            reply[0] = 129
            return [
                SocketDatagram(bytes: [2, 0, 0, 0, 0, 0, 5, 0] + header + request, receivedAt: .now()),
                SocketDatagram(bytes: reply, receivedAt: .now(), source: .ipv6(target)),
            ]
        })
        let pinger = Pinger(
            host: "::1", configuration: .init(count: .times(1), addressFamily: .ipv6),
            socketFactory: { _ in socket }, resolver: { _ in .ipv6(target) })
        for try await event in pinger.responses {
            if case .sent = event { continue }
            if case .reply = event { continue }
            Issue.record("foreign quoted IPv6 destination was accepted: \(event)")
        }
    }
}
