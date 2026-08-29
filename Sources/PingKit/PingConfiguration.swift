/// Options controlling a `Pinger` run.
public struct PingConfiguration: Sendable {
    /// Which IP family a run resolves the host to and sends over.
    public enum AddressFamily: Sendable, Equatable {
        /// Follow `getaddrinfo` ordering, including DNS64/NAT64 results.
        case automatic
        case ipv4
        case ipv6
    }

    /// How many probes a run sends before its sequence finishes.
    public enum Count: Sendable, Equatable {
        case unlimited
        case times(Int)
    }

    /// Delay between successive echo requests.
    public var interval: Duration
    /// How long to wait for each reply before reporting `.timeout`.
    public var timeout: Duration
    /// How many probes to send before the response sequence finishes.
    public var count: Count
    /// Echo payload size in bytes (the classic default is 56, for 64-byte
    /// ICMP messages).
    public var payloadSize: Int
    /// IPv4 TTL or IPv6 unicast hop limit for outgoing probes (1...255);
    /// `nil` keeps the system default.
    public var timeToLive: Int?
    /// Address family used to resolve and contact the host.
    public var addressFamily: AddressFamily

    public init(
        interval: Duration = .seconds(1),
        timeout: Duration = .seconds(2),
        count: Count = .unlimited,
        payloadSize: Int = 56,
        timeToLive: Int? = nil,
        addressFamily: AddressFamily = .automatic
    ) {
        self.interval = interval
        self.timeout = timeout
        self.count = count
        self.payloadSize = payloadSize
        self.timeToLive = timeToLive
        self.addressFamily = addressFamily
    }

    func validate() throws {
        guard interval > .zero,
              timeout > .zero,
              payloadSize >= 0,
              payloadSize <= 65_507,
              count.isValid,
              timeToLive.map((1...255).contains) ?? true else {
            throw PingError.invalidConfiguration
        }
    }
}

private extension PingConfiguration.Count {
    var isValid: Bool {
        switch self {
        case .unlimited:
            true
        case .times(let count):
            count > 0
        }
    }
}
