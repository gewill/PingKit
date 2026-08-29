/// Options controlling a `Tracer` run.
public struct TracerouteConfiguration: Sendable {
    /// Highest TTL to probe before giving up on reaching the destination.
    public var maxHops: Int
    /// Echo requests sent at each TTL (classic traceroute sends 3).
    public var probesPerHop: Int
    /// How long to wait for each probe's answer.
    public var timeout: Duration
    /// Echo payload size in bytes.
    public var payloadSize: Int

    public init(
        maxHops: Int = 30,
        probesPerHop: Int = 3,
        timeout: Duration = .seconds(1),
        payloadSize: Int = 16
    ) {
        self.maxHops = maxHops
        self.probesPerHop = probesPerHop
        self.timeout = timeout
        self.payloadSize = payloadSize
    }

    func validate() throws {
        guard (1...255).contains(maxHops),
              (1...16).contains(probesPerHop),
              timeout > .zero,
              payloadSize >= 0,
              payloadSize <= 65_507 else {
            throw PingError.invalidConfiguration
        }
    }
}

/// One row of a traceroute: everything learned at a single TTL.
public struct TracerouteHop: Sendable, Equatable {
    public let ttl: Int
    /// One entry per probe, in send order.
    public let probes: [TracerouteProbe]

    /// Whether any probe at this TTL was answered by the destination itself
    /// (echo reply) — the trace ends after such a hop.
    public var reachedDestination: Bool {
        probes.contains { probe in
            if case .response(_, _, .destination) = probe { return true }
            return false
        }
    }

    public init(ttl: Int, probes: [TracerouteProbe]) {
        self.ttl = ttl
        self.probes = probes
    }
}

/// Outcome of a single traceroute probe.
public enum TracerouteProbe: Sendable, Equatable {
    /// A router (or the destination) answered.
    case response(router: IPv4Endpoint, roundTripTime: Duration, kind: Kind)
    /// Nothing answered within the timeout (printed as `*` by traceroute).
    case timeout

    /// What answered a probe, which also decides whether the trace
    /// continues past this hop.
    public enum Kind: Sendable, Equatable {
        /// ICMP Time Exceeded from an intermediate router.
        case hop
        /// Echo reply from the destination.
        case destination
        /// ICMP Destination Unreachable; the trace ends after this hop.
        case unreachable(code: UInt8)
    }
}
