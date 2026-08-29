/// An ICMP traceroute client: sends echo requests with increasing TTL and
/// reads the ICMP Time Exceeded answers from intermediate routers.
///
/// ```swift
/// let tracer = Tracer(host: "example.com")
/// for try await hop in tracer.hops {
///     print(hop.ttl, hop.probes)
/// }
/// ```
///
/// Same lifecycle contract as `Pinger`: `hops` supports a single consumer,
/// cancelling the consuming task stops the trace, and `stop()` is an
/// idempotent explicit shutdown.
///
/// Platform note: Darwin delivers ICMP errors to the unprivileged ICMP
/// socket, so hop discovery works there. Linux routes them to the socket
/// error queue instead, which PingKit doesn't read yet — intermediate hops
/// show as timeouts on Linux; the destination reply still arrives.
public actor Tracer {
    typealias SocketFactory = @Sendable (IPv4Endpoint) throws -> any PingSocket
    typealias HostResolver = @Sendable (String) async throws -> IPv4Endpoint

    private let host: String
    private let configuration: TracerouteConfiguration
    private let socketFactory: SocketFactory
    private let resolver: HostResolver
    private let identifier = UInt16.random(in: 1 ... .max)

    private enum State {
        case idle
        case running
        case stopped
    }

    private var state: State = .idle
    private var claimed = false
    private var endpoint: IPv4Endpoint?
    private var socket: (any PingSocket)?
    private var continuation: AsyncThrowingStream<TracerouteHop, any Error>.Continuation?
    private var runTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var receiveContinuation: AsyncStream<SocketDatagram>.Continuation?
    private var awaiting: Awaiting?

    private struct Awaiting {
        let sequence: UInt16
        let sentAt: MonotonicTimestamp
        let continuation: CheckedContinuation<ProbeOutcome, Never>
        let timeoutTask: Task<Void, Never>
    }

    private enum ProbeOutcome {
        case answered(router: IPv4Endpoint, roundTripTime: Duration, kind: TracerouteProbe.Kind)
        case timedOut
        case aborted
    }

    public init(host: String, configuration: TracerouteConfiguration = TracerouteConfiguration()) {
        self.init(
            host: host,
            configuration: configuration,
            socketFactory: { try ICMPv4Socket(destination: $0) },
            resolver: { try await Resolver.resolveIPv4($0) })
    }

    init(
        host: String,
        configuration: TracerouteConfiguration,
        socketFactory: @escaping SocketFactory,
        resolver: @escaping HostResolver
    ) {
        self.host = host
        self.configuration = configuration
        self.socketFactory = socketFactory
        self.resolver = resolver
    }

    deinit {
        runTask?.cancel()
        receiveTask?.cancel()
        socket?.close()
    }

    /// Runs a complete trace and returns every hop.
    public static func trace(
        _ host: String,
        configuration: TracerouteConfiguration = TracerouteConfiguration()
    ) async throws -> [TracerouteHop] {
        let tracer = Tracer(host: host, configuration: configuration)
        var hops: [TracerouteHop] = []
        for try await hop in tracer.hops {
            hops.append(hop)
        }
        return hops
    }

    /// The stream of hops, one per TTL. Resolution and socket setup happen
    /// lazily on the first iteration, so errors surface from the first `next()`.
    public nonisolated var hops: TracerouteHops {
        TracerouteHops(tracer: self)
    }

    /// Stops probing, closes the socket, and finishes the hop sequence.
    /// Safe to call any number of times, from anywhere.
    public func stop() {
        stopInternal()
    }

    // MARK: - Machinery

    func claimAndStart() async throws -> AsyncThrowingStream<TracerouteHop, any Error> {
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
            try socket.activate { [weak self] datagram in
                guard self != nil else { return }
                receiveContinuation.yield(datagram)
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

        let (stream, continuation) = AsyncThrowingStream<TracerouteHop, any Error>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.stop() }
        }
        runTask = Task { await self.runTrace() }
        return stream
    }

    private static func finishedStream() -> AsyncThrowingStream<TracerouteHop, any Error> {
        let (stream, continuation) = AsyncThrowingStream<TracerouteHop, any Error>.makeStream()
        continuation.finish()
        return stream
    }

    private func runTrace() async {
        var sequence: UInt16 = 0
        for ttl in 1...configuration.maxHops {
            guard case .running = state else { return }
            var probes: [TracerouteProbe] = []
            var finished = false
            for _ in 0..<configuration.probesPerHop {
                guard case .running = state else { return }
                sequence &+= 1
                switch await sendProbeAndWait(ttl: ttl, sequence: sequence) {
                case .answered(let router, let roundTripTime, let kind):
                    probes.append(.response(router: router, roundTripTime: roundTripTime, kind: kind))
                    if kind != .hop { finished = true }
                case .timedOut:
                    probes.append(.timeout)
                case .aborted:
                    return
                }
            }
            continuation?.yield(TracerouteHop(ttl: ttl, probes: probes))
            if finished { break }
        }
        stopInternal()
    }

    private func sendProbeAndWait(ttl: Int, sequence: UInt16) async -> ProbeOutcome {
        guard case .running = state, let socket, let continuation else { return .aborted }
        do {
            try socket.setTimeToLive(ttl)
            let packet = ICMPv4.makeEchoRequest(
                identifier: identifier,
                sequence: sequence,
                payload: ICMPv4.payloadPattern(size: configuration.payloadSize))
            let sentAt = MonotonicTimestamp.now()
            try socket.send(packet)
            let timeout = configuration.timeout
            return await withCheckedContinuation { probeContinuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.probeTimedOut(sequence: sequence)
                }
                awaiting = Awaiting(
                    sequence: sequence,
                    sentAt: sentAt,
                    continuation: probeContinuation,
                    timeoutTask: timeoutTask)
            }
        } catch {
            continuation.finish(throwing: error)
            stopInternal()
            return .aborted
        }
    }

    private func probeTimedOut(sequence: UInt16) {
        guard let awaiting, awaiting.sequence == sequence else { return }
        self.awaiting = nil
        awaiting.continuation.resume(returning: .timedOut)
    }

    private func handleDatagram(_ datagram: [UInt8], receivedAt: MonotonicTimestamp) {
        guard case .running = state, let awaiting else { return }
        guard let packet = ReceivedPacket.parse(datagram) else { return }

        let outcome: ProbeOutcome
        switch packet.message {
        case .echoReply(let replyIdentifier, let sequence, _):
            #if !os(Linux)
            guard replyIdentifier == identifier else { return }
            #else
            _ = replyIdentifier
            #endif
            guard sequence == awaiting.sequence else { return }
            outcome = .answered(
                router: packet.source ?? endpoint ?? IPv4Endpoint(rawAddress: 0),
                roundTripTime: receivedAt.duration(since: awaiting.sentAt),
                kind: .destination)

        case .timeExceeded(_, let probeReference):
            guard let probeReference, probeMatches(probeReference),
                  probeReference.sequence == awaiting.sequence else { return }
            outcome = .answered(
                router: packet.source ?? IPv4Endpoint(rawAddress: 0),
                roundTripTime: receivedAt.duration(since: awaiting.sentAt),
                kind: .hop)

        case .destinationUnreachable(let code, let probeReference):
            guard let probeReference, probeMatches(probeReference),
                  probeReference.sequence == awaiting.sequence else { return }
            outcome = .answered(
                router: packet.source ?? IPv4Endpoint(rawAddress: 0),
                roundTripTime: receivedAt.duration(since: awaiting.sentAt),
                kind: .unreachable(code: code))

        case .echoRequest, .other:
            return
        }

        self.awaiting = nil
        awaiting.timeoutTask.cancel()
        awaiting.continuation.resume(returning: outcome)
    }

    private func probeMatches(_ probe: EmbeddedProbe) -> Bool {
        #if os(Linux)
        return true
        #else
        return probe.identifier == identifier
        #endif
    }

    private func stopInternal() {
        if case .stopped = state { return }
        state = .stopped
        runTask?.cancel()
        runTask = nil
        receiveContinuation?.finish()
        receiveContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        if let awaiting {
            self.awaiting = nil
            awaiting.timeoutTask.cancel()
            awaiting.continuation.resume(returning: .aborted)
        }
        socket?.close()
        socket = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.finish()
    }
}

/// The `AsyncSequence` of `TracerouteHop`s produced by a `Tracer`.
public struct TracerouteHops: AsyncSequence, Sendable {
    public typealias Element = TracerouteHop

    let tracer: Tracer

    public func makeAsyncIterator() -> Iterator {
        Iterator(tracer: tracer)
    }

    /// Iterator for ``TracerouteHops``.
    ///
    /// The trace starts on the first `next()`: that is where resolution and
    /// socket setup happen, where their errors surface, and where a second
    /// consumer is rejected with ``PingError/sequenceAlreadyConsumed``.
    public struct Iterator: AsyncIteratorProtocol {
        private let tracer: Tracer
        private var streamIterator: AsyncThrowingStream<TracerouteHop, any Error>.Iterator?
        private var finished = false

        init(tracer: Tracer) {
            self.tracer = tracer
        }

        public mutating func next() async throws -> TracerouteHop? {
            if finished { return nil }
            if streamIterator == nil {
                do {
                    streamIterator = try await tracer.claimAndStart().makeAsyncIterator()
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
