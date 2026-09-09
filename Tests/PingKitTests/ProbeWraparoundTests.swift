import Testing
@testable import PingKit

@Suite struct ProbeWraparoundTests {
    private func pinger(_ socket: MockPingSocket, count: PingConfiguration.Count = .times(3)) -> Pinger {
        Pinger(
            host: "test.invalid",
            configuration: .init(interval: .nanoseconds(1), timeout: .seconds(60), count: count),
            socketFactory: { _ in socket },
            resolver: { _ in .ipv4(IPv4Endpoint(127, 0, 0, 1)) },
            sequenceLimit: 1)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline, "state transition did not complete")
            await Task.yield()
        }
    }

    @Test func wrapWaitsAndStaleTimeoutCannotCompleteNewProbe() async throws {
        let socket = MockPingSocket()
        let pinger = pinger(socket)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            await pinger.stop()
        }
        defer { watchdog.cancel() }
        let consumer = Task {
            var events: [PingResponse] = []
            for try await event in pinger.responses { events.append(event) }
            return events
        }
        defer { consumer.cancel() }
        try await waitUntil { await pinger.waitingSequence == 0 || socket.sent.count >= 3 }
        #expect(socket.sent.count == 2)
        #expect(await pinger.waitingSequence == 0)

        await pinger.handleTimeout(sequence: 0, generation: 1)
        try await waitUntil { socket.sent.count == 3 }
        // This models an old callback already queued on the actor before
        // its timeout task was cancelled.
        await pinger.handleTimeout(sequence: 0, generation: 1)
        await pinger.handleTimeout(sequence: 1, generation: 2)
        await pinger.handleTimeout(sequence: 0, generation: 3)

        let events = try await consumer.value
        #expect(events == [
            .sent(sequence: 0), .sent(sequence: 1), .timeout(sequence: 0),
            .sent(sequence: 0), .timeout(sequence: 1), .timeout(sequence: 0),
        ])
        #expect(socket.closed)
        #expect(await pinger.statistics().transmitted == 3)
    }

    @Test(arguments: [false, true])
    func stoppingReleasesSequenceWaiter(cancelConsumer: Bool) async throws {
        let socket = MockPingSocket()
        let pinger = pinger(socket, count: .unlimited)
        let consumer = Task {
            for try await _ in pinger.responses {}
        }
        do {
            try await waitUntil { await pinger.waitingSequence == 0 || socket.sent.count > 2 }
            #expect(socket.sent.count == 2)
            if cancelConsumer { consumer.cancel() } else { await pinger.stop() }
            try await consumer.value
            try await waitUntil { socket.closed }
            #expect(await pinger.waitingSequence == nil)
            #expect(socket.sent.count == 2)
        } catch {
            await pinger.stop()
            consumer.cancel()
            throw error
        }
    }
}
