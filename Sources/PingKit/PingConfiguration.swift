/// Options controlling a `Pinger` run.
public struct PingConfiguration: Sendable {
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

    public init(
        interval: Duration = .seconds(1),
        timeout: Duration = .seconds(2),
        count: Count = .unlimited,
        payloadSize: Int = 56
    ) {
        self.interval = interval
        self.timeout = timeout
        self.count = count
        self.payloadSize = payloadSize
    }

    func validate() throws {
        guard interval > .zero,
              timeout > .zero,
              payloadSize >= 0,
              payloadSize <= 65_507,
              count.isValid else {
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
