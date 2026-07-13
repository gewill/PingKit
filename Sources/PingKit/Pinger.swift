/// An ICMP ping client.
///
/// ```swift
/// // One-shot
/// let reply = try await Pinger.ping("example.com")
///
/// // Continuous
/// let pinger = Pinger(host: "1.1.1.1", configuration: .init(count: .times(5)))
/// for try await response in pinger.responses {
///     print(response)
/// }
/// let stats = await pinger.statistics()
/// ```
///
/// Lifecycle semantics:
/// - `responses` supports a **single consumer**; a second subscription throws
///   `PingError.sequenceAlreadyConsumed`.
/// - Cancelling the consuming task stops sending, closes the socket, and ends
///   the sequence.
/// - Breaking out of the loop without cancelling does **not** stop the pinger
///   by itself in all cases — call `stop()` (idempotent) when done early.
public actor Pinger {
    typealias SocketFactory = @Sendable (IPv4Endpoint) throws -> any PingSocket
    typealias HostResolver = @Sendable (String) async throws -> IPv4Endpoint

    private enum State {
        case idle
        case running
        case stopped
    }

    private let host: String
    private let configuration: PingConfiguration
    private let socketFactory: SocketFactory
    private let resolver: HostResolver
    private let identifier = UInt16.random(in: 1 ... .max)

    private var state: State = .idle
    private var claimed = false
    private var endpoint: IPv4Endpoint?
    private var socket: (any PingSocket)?
    private var continuation: AsyncThrowingStream<PingResponse, any Error>.Continuation?
    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var receiveContinuation: AsyncStream<SocketDatagram>.Continuation?
    private var pending: [UInt16: Probe] = [:]

    private var transmitted = 0
    private var received = 0
    private var completed = 0
    private var rttSum = 0.0
    private var rttSquaredSum = 0.0
    private var minRTT: Duration?
    private var maxRTT: Duration?

    private struct Probe {
        let sentAt: MonotonicTimestamp
        let timeoutTask: Task<Void, Never>
    }

    public init(host: String, configuration: PingConfiguration = PingConfiguration()) {
        self.init(
            host: host,
            configuration: configuration,
            socketFactory: { try ICMPv4Socket(destination: $0) },
            resolver: { try await Resolver.resolveIPv4($0) })
    }

    init(
        host: String,
        configuration: PingConfiguration,
        socketFactory: @escaping SocketFactory,
        resolver: @escaping HostResolver
    ) {
        self.host = host
        self.configuration = configuration
        self.socketFactory = socketFactory
        self.resolver = resolver
    }

    deinit {
        sendTask?.cancel()
        receiveTask?.cancel()
        socket?.close()
    }

    /// Sends a single echo request and returns the reply, throwing on
    /// timeout or an ICMP error response.
    public static func ping(
        _ host: String,
        timeout: Duration = .seconds(2),
        payloadSize: Int = 56
    ) async throws -> PingReply {
        let configuration = PingConfiguration(timeout: timeout, count: .times(1), payloadSize: payloadSize)
        let pinger = Pinger(host: host, configuration: configuration)
        for try await response in pinger.responses {
            switch response {
            case .reply(let reply):
                return reply
            case .timeout:
                throw PingError.timedOut
            case .unreachable(_, let code):
                throw PingError.destinationUnreachable(code: code)
            case .timeExceeded:
                throw PingError.timeToLiveExceeded
            }
        }
        throw PingError.timedOut
    }

    /// The stream of ping events. Resolution and socket setup happen lazily on
    /// the first iteration, so errors surface from the first `next()`.
    public nonisolated var responses: PingResponses {
        PingResponses(pinger: self)
    }

    /// Stops sending, cancels pending timeouts, closes the socket, and
    /// finishes the response sequence. Safe to call any number of times,
    /// from anywhere.
    public func stop() {
        stopInternal()
    }

    /// A snapshot of the run's statistics so far.
    public func statistics() -> PingStatistics {
        var average: Duration?
        var stddev: Duration?
        if received > 0 {
            let mean = rttSum / Double(received)
            average = .seconds(mean)
            let variance = max(0, rttSquaredSum / Double(received) - mean * mean)
            stddev = .seconds(variance.squareRoot())
        }
        return PingStatistics(
            transmitted: transmitted,
            received: received,
            minRTT: minRTT,
            averageRTT: average,
            maxRTT: maxRTT,
            stddevRTT: stddev)
    }

    // MARK: - Machinery

    func claimAndStart() async throws -> AsyncThrowingStream<PingResponse, any Error> {
        try configuration.validate()
        guard !claimed else { throw PingError.sequenceAlreadyConsumed }
        claimed = true

        if case .stopped = state { return Self.finishedStream() }
        state = .running

        let endpoint: IPv4Endpoint
        do {
            endpoint = try await resolver(host)
        } catch {
            stopInternal()
            throw error
        }
        // The pinger may have been stopped or the consumer cancelled while
        // resolution was in flight; discard the result in that case.
        guard case .running = state, !Task.isCancelled else {
            stopInternal()
            return Self.finishedStream()
        }
        self.endpoint = endpoint

        do {
            let socket = try socketFactory(endpoint)
            self.socket = socket
            let (datagrams, receiveContinuation) = AsyncStream<SocketDatagram>.makeStream()
            self.receiveContinuation = receiveContinuation
            try socket.activate { [weak self] datagram, receivedAt in
                guard self != nil else { return }
                receiveContinuation.yield(SocketDatagram(bytes: datagram, receivedAt: receivedAt))
            }
            receiveTask = Task { [weak self] in
                for await datagram in datagrams {
                    guard let self else { return }
                    await self.handleDatagram(datagram.bytes, receivedAt: datagram.receivedAt)
                }
            }
        } catch {
            stopInternal()
            throw error
        }

        let (stream, continuation) = AsyncThrowingStream<PingResponse, any Error>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.stop() }
        }
        startSendLoop()
        return stream
    }

    private static func finishedStream() -> AsyncThrowingStream<PingResponse, any Error> {
        let (stream, continuation) = AsyncThrowingStream<PingResponse, any Error>.makeStream()
        continuation.finish()
        return stream
    }

    private func startSendLoop() {
        let count = configuration.count
        let interval = configuration.interval
        sendTask = Task { [weak self] in
            var sequence: UInt16 = 0
            var sent = 0
            while !Task.isCancelled {
                let proceeded: Bool
                if let self {
                    proceeded = await self.sendProbe(sequence: sequence)
                } else {
                    return
                }
                guard proceeded else { return }
                sent += 1
                sequence &+= 1
                if case .times(let n) = count, sent >= n { return }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func sendProbe(sequence: UInt16) -> Bool {
        guard case .running = state, let socket, let continuation else { return false }
        let payload = ICMPv4.payloadPattern(size: configuration.payloadSize)
        let packet = ICMPv4.makeEchoRequest(identifier: identifier, sequence: sequence, payload: payload)
        let sentAt = MonotonicTimestamp.now()
        do {
            try socket.send(packet)
        } catch {
            continuation.finish(throwing: error)
            stopInternal()
            return false
        }
        transmitted += 1
        let timeout = configuration.timeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.handleTimeout(sequence: sequence)
        }
        pending[sequence] = Probe(sentAt: sentAt, timeoutTask: timeoutTask)
        return true
    }

    private func handleDatagram(_ datagram: [UInt8], receivedAt: MonotonicTimestamp) {
        guard case .running = state else { return }
        guard let packet = ReceivedPacket.parse(datagram) else { return }

        switch packet.message {
        case .echoReply(let replyIdentifier, let sequence, let payloadCount):
            // The Linux kernel rewrites the echo identifier on datagram ICMP
            // sockets, so it can't be matched there; Darwin preserves it.
            #if !os(Linux)
            guard replyIdentifier == identifier else { return }
            #else
            _ = replyIdentifier
            #endif
            guard let probe = pending.removeValue(forKey: sequence) else { return }
            probe.timeoutTask.cancel()
            let rtt = receivedAt.duration(since: probe.sentAt)
            recordRTT(rtt)
            let reply = PingReply(
                sequence: sequence,
                roundTripTime: rtt,
                timeToLive: packet.timeToLive,
                from: packet.source ?? endpoint ?? IPv4Endpoint(rawAddress: 0),
                byteCount: ICMPv4.headerSize + payloadCount)
            continuation?.yield(.reply(reply))
            completeProbe()

        case .destinationUnreachable(let code, let probeReference):
            guard let probeReference, probeMatches(probeReference),
                  let probe = pending.removeValue(forKey: probeReference.sequence) else { return }
            probe.timeoutTask.cancel()
            continuation?.yield(.unreachable(sequence: probeReference.sequence, code: code))
            completeProbe()

        case .timeExceeded(_, let probeReference):
            guard let probeReference, probeMatches(probeReference),
                  let probe = pending.removeValue(forKey: probeReference.sequence) else { return }
            probe.timeoutTask.cancel()
            continuation?.yield(.timeExceeded(sequence: probeReference.sequence))
            completeProbe()

        case .echoRequest, .other:
            // Pinging localhost can deliver our own request back; ignore it
            // along with any unrelated ICMP traffic.
            return
        }
    }

    private func handleTimeout(sequence: UInt16) {
        guard case .running = state else { return }
        guard pending.removeValue(forKey: sequence) != nil else { return }
        continuation?.yield(.timeout(sequence: sequence))
        completeProbe()
    }

    private func probeMatches(_ probe: EmbeddedProbe) -> Bool {
        #if os(Linux)
        return true
        #else
        return probe.identifier == identifier
        #endif
    }

    private func recordRTT(_ rtt: Duration) {
        received += 1
        let seconds = rtt.secondsDouble
        rttSum += seconds
        rttSquaredSum += seconds * seconds
        if minRTT == nil || rtt < minRTT! { minRTT = rtt }
        if maxRTT == nil || rtt > maxRTT! { maxRTT = rtt }
    }

    private func completeProbe() {
        completed += 1
        if case .times(let n) = configuration.count, completed >= n {
            stopInternal()
        }
    }

    private func stopInternal() {
        if case .stopped = state { return }
        state = .stopped
        sendTask?.cancel()
        sendTask = nil
        receiveContinuation?.finish()
        receiveContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        for probe in pending.values {
            probe.timeoutTask.cancel()
        }
        pending.removeAll()
        socket?.close()
        socket = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.finish()
    }
}

/// The `AsyncSequence` of `PingResponse` events produced by a `Pinger`.
public struct PingResponses: AsyncSequence, Sendable {
    public typealias Element = PingResponse

    let pinger: Pinger

    public func makeAsyncIterator() -> Iterator {
        Iterator(pinger: pinger)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private let pinger: Pinger
        private var streamIterator: AsyncThrowingStream<PingResponse, any Error>.Iterator?
        private var finished = false

        init(pinger: Pinger) {
            self.pinger = pinger
        }

        public mutating func next() async throws -> PingResponse? {
            if finished { return nil }
            if streamIterator == nil {
                do {
                    streamIterator = try await pinger.claimAndStart().makeAsyncIterator()
                } catch {
                    finished = true
                    throw error
                }
            }
            var iterator = streamIterator!
            do {
                let element = try await iterator.next()
                streamIterator = iterator
                if element == nil { finished = true }
                return element
            } catch {
                streamIterator = iterator
                finished = true
                throw error
            }
        }
    }
}
