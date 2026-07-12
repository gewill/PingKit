import Testing
@testable import PingKit

@Suite struct PingerTests {
    @Test(arguments: [
        PingConfiguration(interval: .zero),
        PingConfiguration(timeout: .zero),
        PingConfiguration(count: .times(0)),
        PingConfiguration(payloadSize: -1),
        PingConfiguration(payloadSize: 65_508),
    ])
    func invalidConfigurationIsReportedAsAnError(_ configuration: PingConfiguration) async {
        let pinger = makePinger(
            configuration: configuration,
            socket: MockPingSocket())

        await #expect(throws: PingError.invalidConfiguration) {
            for try await _ in pinger.responses {}
        }
    }

    @Test func repliesArriveInOrder() async throws {
        let socket = MockPingSocket(autoReply: { Fixtures.replyDatagram(forRequest: $0) })
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .seconds(2), count: .times(3)),
            socket: socket)

        var sequences: [UInt16] = []
        for try await response in pinger.responses {
            guard case .reply(let reply) = response else {
                Issue.record("unexpected response \(response)")
                return
            }
            sequences.append(reply.sequence)
            #expect(reply.timeToLive == 64)
            #expect(reply.byteCount == 64)
            #expect(reply.from == IPv4Endpoint(127, 0, 0, 1))
            #expect(reply.roundTripTime >= .zero)
        }
        #expect(sequences == [0, 1, 2])

        let statistics = await pinger.statistics()
        #expect(statistics.transmitted == 3)
        #expect(statistics.received == 3)
        #expect(statistics.lossRate == 0)
        #expect(statistics.averageRTT != nil)
        #expect(socket.closed)
    }

    @Test func timeoutsReported() async throws {
        let socket = MockPingSocket()
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .milliseconds(30), count: .times(2)),
            socket: socket)

        var events: [PingResponse] = []
        for try await response in pinger.responses {
            events.append(response)
        }
        #expect(events == [.timeout(sequence: 0), .timeout(sequence: 1)])

        let statistics = await pinger.statistics()
        #expect(statistics.transmitted == 2)
        #expect(statistics.received == 0)
        #expect(statistics.lost == 2)
        #expect(statistics.lossRate == 1)
    }

    @Test func duplicateReplyCountedOnce() async throws {
        let socket = MockPingSocket()
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .milliseconds(50), count: .times(2)),
            socket: socket)

        let injector = Task {
            while socket.sent.isEmpty {
                try await Task.sleep(for: .milliseconds(1))
            }
            let reply = Fixtures.replyDatagram(forRequest: socket.sent[0])
            socket.inject(reply)
            socket.inject(reply)
        }

        var replies = 0
        var timeouts = 0
        for try await response in pinger.responses {
            if case .reply = response { replies += 1 } else { timeouts += 1 }
        }
        _ = try? await injector.value

        #expect(replies == 1)
        #expect(timeouts == 1)
        let statistics = await pinger.statistics()
        #expect(statistics.received == 1)
    }

    @Test func mismatchedIdentifierIgnored() async throws {
        let socket = MockPingSocket()
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .milliseconds(40), count: .times(1)),
            socket: socket)

        let injector = Task {
            while socket.sent.isEmpty {
                try await Task.sleep(for: .milliseconds(1))
            }
            // Same sequence, wrong identifier: must not match the probe.
            let stray = Fixtures.ipv4Datagram(payload: Fixtures.echoReply(identifier: 0, sequence: 0, payload: []))
            socket.inject(stray)
        }

        var events: [PingResponse] = []
        for try await response in pinger.responses {
            events.append(response)
        }
        _ = try? await injector.value
        #expect(events == [.timeout(sequence: 0)])
    }

    @Test func unreachableMapped() async throws {
        let socket = MockPingSocket(autoReply: { Fixtures.unreachableDatagram(forRequest: $0, code: 1) })
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .seconds(1), count: .times(1)),
            socket: socket)

        var events: [PingResponse] = []
        for try await response in pinger.responses {
            events.append(response)
        }
        #expect(events == [.unreachable(sequence: 0, code: 1)])
    }

    @Test func secondConsumerRejected() async throws {
        let socket = MockPingSocket(autoReply: { Fixtures.replyDatagram(forRequest: $0) })
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .seconds(1), count: .times(1)),
            socket: socket)

        for try await _ in pinger.responses {}

        await #expect(throws: PingError.responsesAlreadyConsumed) {
            for try await _ in pinger.responses {}
        }
    }

    @Test func stopEndsStreamAndIsIdempotent() async throws {
        let socket = MockPingSocket()
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(10), timeout: .seconds(5), count: .unlimited),
            socket: socket)

        let consumer = Task {
            var events = 0
            for try await _ in pinger.responses {
                events += 1
            }
            return events
        }
        try await Task.sleep(for: .milliseconds(50))
        await pinger.stop()
        await pinger.stop()

        let events = try await consumer.value
        #expect(events == 0)
        #expect(socket.closed)
        let statistics = await pinger.statistics()
        #expect(statistics.transmitted >= 1)
    }

    @Test func cancellationStopsPinger() async throws {
        let socket = MockPingSocket()
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(10), timeout: .seconds(5), count: .unlimited),
            socket: socket)

        let consumer = Task {
            for try await _ in pinger.responses {}
        }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = try? await consumer.value

        // Teardown runs on a detached task kicked off by stream termination.
        for _ in 0..<200 where !socket.closed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(socket.closed)
    }

    @Test func breakingResponseIterationStopsPinger() async throws {
        let socket = MockPingSocket(autoReply: { Fixtures.replyDatagram(forRequest: $0) })
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(10), timeout: .seconds(1), count: .unlimited),
            socket: socket)

        for try await _ in pinger.responses {
            break
        }

        for _ in 0..<200 where !socket.closed {
            try await Task.sleep(for: .milliseconds(5))
        }
        let sentAfterBreak = socket.sent.count
        try await Task.sleep(for: .milliseconds(30))

        #expect(socket.closed)
        #expect(socket.sent.count == sentAfterBreak)
    }

    @Test func stopBeforeIterationYieldsEmptySequence() async throws {
        let socket = MockPingSocket()
        let pinger = makePinger(
            configuration: PingConfiguration(count: .unlimited),
            socket: socket)

        await pinger.stop()
        var events = 0
        for try await _ in pinger.responses {
            events += 1
        }
        #expect(events == 0)
        #expect(socket.sent.isEmpty)
    }

    @Test func resolutionFailureSurfacesOnFirstNext() async {
        let pinger = Pinger(
            host: "nope.invalid",
            configuration: PingConfiguration(count: .times(1)),
            socketFactory: { _ in MockPingSocket() },
            resolver: { host in throw PingError.resolutionFailed(host: host, code: 8) })

        await #expect(throws: PingError.resolutionFailed(host: "nope.invalid", code: 8)) {
            for try await _ in pinger.responses {}
        }
    }

    @Test func socketCreationFailureSurfacesOnFirstNext() async {
        let pinger = Pinger(
            host: "test.invalid",
            configuration: PingConfiguration(count: .times(1)),
            socketFactory: { _ in throw PingError.socketCreationFailed(errno: 1) },
            resolver: { _ in IPv4Endpoint(127, 0, 0, 1) })

        await #expect(throws: PingError.socketCreationFailed(errno: 1)) {
            for try await _ in pinger.responses {}
        }
    }
}
