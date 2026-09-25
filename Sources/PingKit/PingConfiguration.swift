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
    /// If a wrapped 16-bit sequence number is still in flight, sending
    /// waits for that probe's terminal event before reusing the number.
    public var interval: Duration
    /// How long to wait for each reply before reporting `.timeout`.
    public var timeout: Duration
    /// How many probes to send before the response sequence finishes.
    public var count: Count
    /// Optional finite sending window, measured with a monotonic clock from
    /// the first send opportunity after socket setup. Once elapsed, no new
    /// probes are sent; the sequence remains open until previous probes reply
    /// or time out.
    /// `nil` preserves the usual count/unlimited behavior.
    public var sendDuration: Duration?
    /// Echo payload size in bytes (the classic default is 56, for 64-byte
    /// ICMP messages).
    public var payloadSize: Int
    /// IPv4 TTL or IPv6 unicast hop limit for outgoing probes (1...255);
    /// `nil` keeps the system default.
    public var timeToLive: Int?
    /// Address family used to resolve and contact the host.
    public var addressFamily: AddressFamily
    /// Bounds on public event and internal datagram buffering.
    public var bufferLimits: PingBufferLimits

    public init(
        interval: Duration = .seconds(1),
        timeout: Duration = .seconds(2),
        count: Count = .unlimited,
        sendDuration: Duration? = nil,
        payloadSize: Int = 56,
        timeToLive: Int? = nil,
        addressFamily: AddressFamily = .automatic,
        bufferLimits: PingBufferLimits = PingBufferLimits()
    ) {
        self.interval = interval
        self.timeout = timeout
        self.count = count
        self.sendDuration = sendDuration
        self.payloadSize = payloadSize
        self.timeToLive = timeToLive
        self.addressFamily = addressFamily
        self.bufferLimits = bufferLimits
    }

    func validate() throws {
        guard bufferLimits.isValid,
              interval > .zero,
              timeout > .zero,
              sendDuration.map({ $0 > .zero }) ?? true,
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
