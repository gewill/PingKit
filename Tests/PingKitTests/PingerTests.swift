import Testing
@testable import PingKit

@Suite struct PingerTests {
    @Test(arguments: [
        PingConfiguration(interval: .zero),
        PingConfiguration(timeout: .zero),
        PingConfiguration(count: .times(0)),
        PingConfiguration(payloadSize: -1),
        PingConfiguration(payloadSize: 65_508),
        PingConfiguration(timeToLive: 0),
        PingConfiguration(timeToLive: 256),
    ])
    func invalidConfigurationIsReportedAsAnError(_ configuration: PingConfiguration) async {
        let pinger = makePinger(
            configuration: configuration,
            socket: MockPingSocket())

        await #expect(throws: PingError.invalidConfiguration) {
            for try await _ in pinger.responses {}
        }
    }

    @Test func configuredTimeToLiveAppliedToEveryProbe() async throws {
        let socket = MockPingSocket(autoReply: { Fixtures.replyDatagram(forRequest: $0) })
        let pinger = makePinger(
            configuration: PingConfiguration(
                interval: .milliseconds(5), timeout: .seconds(1), count: .times(2), timeToLive: 1),
            socket: socket)

        for try await _ in pinger.responses {}

        #expect(socket.sentTTLs == [1, 1])
    }

    @Test func timeToLiveSocketFailureSurfacesOnFirstNext() async {
        let socket = MockPingSocket(setTimeToLiveError: .socketOptionFailed(errno: 22))
        let pinger = makePinger(
            configuration: PingConfiguration(count: .times(1), timeToLive: 8),
            socket: socket)

        await #expect(throws: PingError.socketOptionFailed(errno: 22)) {
            for try await _ in pinger.responses {}
        }
        #expect(socket.closed)
        #expect(socket.sent.isEmpty)
    }

    @Test func sentEventPrecedesReply() async throws {
        let socket = MockPingSocket(autoReply: { Fixtures.replyDatagram(forRequest: $0) })
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .seconds(1), count: .times(1)),
            socket: socket)

        var events: [PingResponse] = []
        for try await response in pinger.responses {
            events.append(response)
        }

        #expect(events.count == 2)
        #expect(events.first == .sent(sequence: 0))
        guard case .reply(let reply)? = events.last else {
            Issue.record("expected a reply, got \(String(describing: events.last))")
            return
        }
        #expect(reply.sequence == 0)
    }

    @Test func sentEventPrecedesTimeout() async throws {
        let socket = MockPingSocket()
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .milliseconds(30), count: .times(1)),
            socket: socket)

        var events: [PingResponse] = []
        for try await response in pinger.responses {
            events.append(response)
        }

        #expect(events == [.sent(sequence: 0), .timeout(sequence: 0)])
    }

    @Test func repliesArriveInOrder() async throws {
        let socket = MockPingSocket(autoReply: { Fixtures.replyDatagram(forRequest: $0) })
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .seconds(2), count: .times(3)),
            socket: socket)

        var sequences: [UInt16] = []
        for try await response in pinger.responses {
            if case .sent = response { continue }
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

    @Test func replyBurstPreservesSocketDeliveryOrder() async throws {
        let replyCount = 100
        let socket = BurstReplySocket(replyCount: replyCount)
        let pinger = Pinger(
            host: "test.invalid",
            configuration: PingConfiguration(
                interval: .microseconds(1),
                // Generous timeout: all sends must complete before any probe
                // times out, and loaded CI simulators stall for seconds.
                timeout: .seconds(60),
                count: .times(replyCount)),
            socketFactory: { _ in socket },
            resolver: { _ in IPv4Endpoint(127, 0, 0, 1) })

        var sequences: [UInt16] = []
        for try await response in pinger.responses {
            if case .sent = response { continue }
            guard case .reply(let reply) = response else {
                Issue.record("unexpected response \(response)")
                return
            }
            sequences.append(reply.sequence)
        }

        #expect(sequences == (0..<replyCount).map(UInt16.init))
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
        // Sends interleave with timeouts on a timing-dependent schedule, so
        // assert each kind's order separately.
        let sends = events.filter { if case .sent = $0 { true } else { false } }
        let timeouts = events.filter { if case .timeout = $0 { true } else { false } }
        #expect(events.count == 4)
        #expect(sends == [.sent(sequence: 0), .sent(sequence: 1)])
        #expect(timeouts == [.timeout(sequence: 0), .timeout(sequence: 1)])

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
            if case .reply = response { replies += 1 }
            if case .timeout = response { timeouts += 1 }
        }
        _ = try? await injector.value

        #expect(replies == 1)
        #expect(timeouts == 1)
        let statistics = await pinger.statistics()
        #expect(statistics.received == 1)
    }

    // On Linux the kernel rewrites the echo identifier on datagram ICMP
    // sockets, so the library deliberately matches by sequence only there;
    // this Darwin-behavior test doesn't apply.
    #if !os(Linux)
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
        #expect(events == [.sent(sequence: 0), .timeout(sequence: 0)])
    }
    #endif

    @Test func unreachableMapped() async throws {
        let socket = MockPingSocket(autoReply: { Fixtures.unreachableDatagram(forRequest: $0, code: 1) })
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .seconds(1), count: .times(1)),
            socket: socket)

        var events: [PingResponse] = []
        for try await response in pinger.responses {
            events.append(response)
        }
        #expect(events == [.sent(sequence: 0), .unreachable(sequence: 0, code: 1)])
    }

    @Test func secondConsumerRejected() async throws {
        let socket = MockPingSocket(autoReply: { Fixtures.replyDatagram(forRequest: $0) })
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(5), timeout: .seconds(1), count: .times(1)),
            socket: socket)

        for try await _ in pinger.responses {}

        await #expect(throws: PingError.sequenceAlreadyConsumed) {
            for try await _ in pinger.responses {}
        }
    }

    @Test func stopEndsStreamAndIsIdempotent() async throws {
        let socket = MockPingSocket()
        let pinger = makePinger(
            configuration: PingConfiguration(interval: .milliseconds(10), timeout: .seconds(5), count: .unlimited),
            socket: socket)

        let consumer = Task {
            var outcomes = 0
            for try await response in pinger.responses {
                if case .sent = response { continue }
                outcomes += 1
            }
            return outcomes
        }
        try await Task.sleep(for: .milliseconds(50))
        await pinger.stop()
        await pinger.stop()

        let outcomes = try await consumer.value
        #expect(outcomes == 0)
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
