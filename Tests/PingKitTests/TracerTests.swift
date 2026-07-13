import Testing
@testable import PingKit

/// Simulates a 3-hop path: routers 10.0.0.1 and 10.0.0.2 answer TTL 1 and 2
/// with Time Exceeded; the destination answers TTL >= 3 with an echo reply.
private let threeHopRoute: @Sendable ([UInt8], Int) -> [UInt8]? = { request, ttl in
    switch ttl {
    case 1: Fixtures.timeExceededDatagram(forRequest: request, source: (10, 0, 0, 1))
    case 2: Fixtures.timeExceededDatagram(forRequest: request, source: (10, 0, 0, 2))
    default: Fixtures.replyDatagram(forRequest: request)
    }
}

private func makeTracer(configuration: TracerouteConfiguration, socket: MockPingSocket) -> Tracer {
    Tracer(
        host: "test.invalid",
        configuration: configuration,
        socketFactory: { _ in socket },
        resolver: { _ in IPv4Endpoint(127, 0, 0, 1) })
}

@Suite struct TracerTests {
    @Test func discoversRouteAndStopsAtDestination() async throws {
        let socket = MockPingSocket(routeReply: threeHopRoute)
        let tracer = makeTracer(
            configuration: TracerouteConfiguration(maxHops: 30, probesPerHop: 1, timeout: .seconds(1)),
            socket: socket)

        var hops: [TracerouteHop] = []
        for try await hop in tracer.hops {
            hops.append(hop)
        }

        #expect(hops.count == 3)
        #expect(hops.map(\.ttl) == [1, 2, 3])
        #expect(socket.sentTTLs == [1, 2, 3])

        guard case .response(let router1, _, .hop) = hops[0].probes.first else {
            Issue.record("unexpected first hop \(hops[0].probes)")
            return
        }
        #expect(router1 == IPv4Endpoint(10, 0, 0, 1))
        #expect(!hops[0].reachedDestination)

        guard case .response(let destination, _, .destination) = hops[2].probes.first else {
            Issue.record("unexpected final hop \(hops[2].probes)")
            return
        }
        #expect(destination == IPv4Endpoint(127, 0, 0, 1))
        #expect(hops[2].reachedDestination)
        #expect(socket.closed)
    }

    @Test func groupsProbesPerHop() async throws {
        let socket = MockPingSocket(routeReply: threeHopRoute)
        let tracer = makeTracer(
            configuration: TracerouteConfiguration(maxHops: 30, probesPerHop: 3, timeout: .seconds(1)),
            socket: socket)

        var hops: [TracerouteHop] = []
        for try await hop in tracer.hops {
            hops.append(hop)
        }

        #expect(hops.count == 3)
        #expect(hops.allSatisfy { $0.probes.count == 3 })
        #expect(socket.sentTTLs == [1, 1, 1, 2, 2, 2, 3, 3, 3])
        // 9 probes, 9 distinct sequence numbers
        let sequences = socket.sent.map { (UInt16($0[6]) << 8) | UInt16($0[7]) }
        #expect(Set(sequences).count == 9)
    }

    @Test func silentRouteYieldsTimeoutsUpToMaxHops() async throws {
        let socket = MockPingSocket()
        let tracer = makeTracer(
            configuration: TracerouteConfiguration(maxHops: 2, probesPerHop: 2, timeout: .milliseconds(30)),
            socket: socket)

        var hops: [TracerouteHop] = []
        for try await hop in tracer.hops {
            hops.append(hop)
        }

        #expect(hops == [
            TracerouteHop(ttl: 1, probes: [.timeout, .timeout]),
            TracerouteHop(ttl: 2, probes: [.timeout, .timeout]),
        ])
        #expect(socket.closed)
    }

    @Test func unreachableEndsTrace() async throws {
        let socket = MockPingSocket(routeReply: { request, ttl in
            switch ttl {
            case 1: Fixtures.timeExceededDatagram(forRequest: request, source: (10, 0, 0, 1))
            default: Fixtures.icmpErrorDatagram(type: 3, code: 13, forRequest: request, source: (10, 0, 0, 9))
            }
        })
        let tracer = makeTracer(
            configuration: TracerouteConfiguration(maxHops: 30, probesPerHop: 1, timeout: .seconds(1)),
            socket: socket)

        var hops: [TracerouteHop] = []
        for try await hop in tracer.hops {
            hops.append(hop)
        }

        #expect(hops.count == 2)
        guard case .response(let router, _, .unreachable(let code)) = hops[1].probes.first else {
            Issue.record("unexpected final hop \(hops[1].probes)")
            return
        }
        #expect(router == IPv4Endpoint(10, 0, 0, 9))
        #expect(code == 13)
        #expect(!hops[1].reachedDestination)
    }

    @Test func staleAnswersIgnored() async throws {
        // The answer for a previous sequence must not satisfy the probe in
        // flight: inject a Time Exceeded quoting the wrong sequence first.
        let socket = MockPingSocket(routeReply: { request, _ in
            var stale = request
            stale[7] &+= 1 // different sequence
            // recompute checksum so only the sequence mismatch is at play
            stale[2] = 0
            stale[3] = 0
            let checksum = ICMPv4.internetChecksum(stale)
            stale[2] = UInt8(checksum >> 8)
            stale[3] = UInt8(checksum & 0xFF)
            return Fixtures.timeExceededDatagram(forRequest: stale, source: (10, 0, 0, 1))
        })
        let tracer = makeTracer(
            configuration: TracerouteConfiguration(maxHops: 1, probesPerHop: 1, timeout: .milliseconds(40)),
            socket: socket)

        var hops: [TracerouteHop] = []
        for try await hop in tracer.hops {
            hops.append(hop)
        }
        #expect(hops == [TracerouteHop(ttl: 1, probes: [.timeout])])
    }

    @Test func secondConsumerRejected() async throws {
        let socket = MockPingSocket(routeReply: threeHopRoute)
        let tracer = makeTracer(
            configuration: TracerouteConfiguration(maxHops: 3, probesPerHop: 1, timeout: .seconds(1)),
            socket: socket)

        for try await _ in tracer.hops {}

        await #expect(throws: PingError.sequenceAlreadyConsumed) {
            for try await _ in tracer.hops {}
        }
    }

    @Test func stopEndsTraceAndIsIdempotent() async throws {
        let socket = MockPingSocket() // silent: every probe waits for timeout
        let tracer = makeTracer(
            configuration: TracerouteConfiguration(maxHops: 30, probesPerHop: 1, timeout: .seconds(5)),
            socket: socket)

        let consumer = Task {
            var hops = 0
            for try await _ in tracer.hops {
                hops += 1
            }
            return hops
        }
        try await Task.sleep(for: .milliseconds(50))
        await tracer.stop()
        await tracer.stop()

        let hops = try await consumer.value
        #expect(hops == 0)
        #expect(socket.closed)
    }

    @Test func cancellationStopsTracer() async throws {
        let socket = MockPingSocket()
        let tracer = makeTracer(
            configuration: TracerouteConfiguration(maxHops: 30, probesPerHop: 1, timeout: .seconds(5)),
            socket: socket)

        let consumer = Task {
            for try await _ in tracer.hops {}
        }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = try? await consumer.value

        for _ in 0..<200 where !socket.closed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(socket.closed)
    }

    @Test(arguments: [
        TracerouteConfiguration(maxHops: 0),
        TracerouteConfiguration(maxHops: 256),
        TracerouteConfiguration(probesPerHop: 0),
        TracerouteConfiguration(timeout: .zero),
        TracerouteConfiguration(payloadSize: -1),
    ])
    func invalidConfigurationIsReportedAsAnError(_ configuration: TracerouteConfiguration) async {
        let tracer = makeTracer(configuration: configuration, socket: MockPingSocket())
        await #expect(throws: PingError.invalidConfiguration) {
            for try await _ in tracer.hops {}
        }
    }
}
