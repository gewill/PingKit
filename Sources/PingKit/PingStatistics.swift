/// Aggregate results of a ping run, in the shape `ping(8)` prints at exit.
public struct PingStatistics: Sendable, Equatable {
    /// Probes attempted, including any the socket rejected — `ping(8)`
    /// counts those too, so a network outage surfaces as loss rather than
    /// vanishing from the aggregate.
    public let transmitted: Int
    /// Probes answered by a matched echo reply. ICMP errors such as
    /// Destination Unreachable do not count as received.
    public let received: Int
    public let minRTT: Duration?
    public let averageRTT: Duration?
    public let maxRTT: Duration?
    /// Population standard deviation of the round-trip times (jitter).
    public let stddevRTT: Duration?

    /// Transmitted probes that no echo reply answered.
    ///
    /// Because only a matched reply increments ``received``, this covers
    /// three different fates at once: timeouts, ICMP errors, and probes the
    /// socket refused to send.
    public var lost: Int { max(0, transmitted - received) }
    /// ``lost`` as a fraction of ``transmitted``; 0 before the first probe.
    public var lossRate: Double { transmitted > 0 ? Double(lost) / Double(transmitted) : 0 }

    public init(transmitted: Int, received: Int, minRTT: Duration?, averageRTT: Duration?, maxRTT: Duration?, stddevRTT: Duration?) {
        self.transmitted = transmitted
        self.received = received
        self.minRTT = minRTT
        self.averageRTT = averageRTT
        self.maxRTT = maxRTT
        self.stddevRTT = stddevRTT
    }
}

extension Duration {
    var secondsDouble: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
