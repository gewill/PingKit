import Testing
@testable import PingKit

@Suite struct BufferOverflowTests {
    private let loopback = IPv4Endpoint(127, 0, 0, 1)

    private func waitForClose(_ socket: MockPingSocket) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !socket.closed {
            try #require(ContinuousClock.now < deadline, "overflow did not close the socket")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func pingDrainsBufferedEventsThenThrows() async throws {
        let socket = MockPingSocket(autoReply: { Fixtures.replyDatagram(forRequest: $0) })
        let pinger = Pinger(
            host: "test.invalid",
            configuration: .init(interval: .seconds(300), timeout: .seconds(300), bufferLimits: .init(events: 1)),
            socketFactory: { _ in socket }, resolver: { _ in .ipv4(loopback) })
        let stream = try await pinger.claimAndStart()
        do { try await waitForClose(socket) } catch { await pinger.stop(); throw error }
        var events: [PingResponse] = []
        do {
            for try await event in stream { events.append(event) }
            Issue.record("overflow must throw")
        } catch {
            #expect(error as? PingError == .bufferOverflow(buffer: .events, capacity: 1))
        }
        #expect(events == [.sent(sequence: 0)])
        #expect(socket.sent.count == 1)
        await pinger.stop()
        #expect(await pinger.waitingSequence == nil)
    }

    @Test func traceDrainsBufferedHopsThenThrows() async throws {
        let socket = MockPingSocket(autoReply: {
            Fixtures.timeExceededDatagram(forRequest: $0, source: (127, 0, 0, 2))
        })
        let tracer = Tracer(
            host: "test.invalid",
            configuration: .init(probesPerHop: 1, timeout: .seconds(300), bufferLimits: .init(events: 1)),
            socketFactory: { _ in socket }, resolver: { _ in loopback })
        let stream = try await tracer.claimAndStart()
        do { try await waitForClose(socket) } catch { await tracer.stop(); throw error }
        var ttls: [Int] = []
        do {
            for try await hop in stream { ttls.append(hop.ttl) }
            Issue.record("overflow must throw")
        } catch {
            #expect(error as? PingError == .bufferOverflow(buffer: .events, capacity: 1))
        }
        #expect(ttls == [1])
        #expect(socket.sent.count == 2)
        await tracer.stop()
    }

    @Test(arguments: [false, true])
    func receiveBurstCannotBecomeTimeoutOrNormalCompletion(trace: Bool) async throws {
        // Inline send holds the actor while these callbacks fill its queue.
        // Include a valid reply first: finishing normally must not hide overflow.
        let socket = MockPingSocket(repliesForIndex: { _, request in
            Array(repeating: Fixtures.replyDatagram(forRequest: request), count: 8)
        })
        let limits = PingBufferLimits(receivedDatagrams: 1)
        if trace {
            let tracer = Tracer(
                host: "test.invalid",
                configuration: .init(probesPerHop: 1, bufferLimits: limits),
                socketFactory: { _ in socket }, resolver: { _ in loopback })
            do {
                for try await _ in tracer.hops {}
                Issue.record("receive overflow must throw")
            } catch {
                #expect(error as? PingError == .bufferOverflow(buffer: .receivedDatagrams, capacity: 1))
            }
            await tracer.stop()
        } else {
            let pinger = Pinger(
                host: "test.invalid",
                configuration: .init(count: .times(1), bufferLimits: limits),
                socketFactory: { _ in socket }, resolver: { _ in .ipv4(loopback) })
            do {
                for try await event in pinger.responses {
                    if case .timeout = event { Issue.record("local overflow is not network timeout") }
                }
                Issue.record("receive overflow must throw")
            } catch {
                #expect(error as? PingError == .bufferOverflow(buffer: .receivedDatagrams, capacity: 1))
            }
            await pinger.stop()
        }
        #expect(socket.closed)
        #expect(socket.sent.count == 1)
    }

    @Test(arguments: [PingBufferLimits(events: 0), .init(receivedDatagrams: -1)])
    func rejectsInvalidLimits(limits: PingBufferLimits) {
        #expect(throws: PingError.invalidConfiguration) {
            try PingConfiguration(bufferLimits: limits).validate()
        }
        #expect(throws: PingError.invalidConfiguration) {
            try TracerouteConfiguration(bufferLimits: limits).validate()
        }
    }
}
