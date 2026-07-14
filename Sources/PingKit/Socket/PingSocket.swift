/// Abstraction over the ICMP socket so `Pinger`'s state machine can be tested
/// with a mock that injects replies, timeouts, and error packets.
protocol PingSocket: Sendable {
    /// Starts receiving. `receiveHandler` is invoked on an arbitrary internal
    /// queue with each raw datagram and available IP-level metadata.
    func activate(receiveHandler: @escaping @Sendable (SocketDatagram) -> Void) throws

    /// Sends one ICMP datagram to the destination the socket was created for.
    func send(_ datagram: [UInt8]) throws

    /// Sets the IPv4 TTL or IPv6 unicast hop limit applied to subsequently
    /// sent datagrams.
    func setTimeToLive(_ ttl: Int) throws

    /// Stops receiving and releases the descriptor. Idempotent.
    func close()
}

struct SocketDatagram: Sendable {
    let bytes: [UInt8]
    let receivedAt: MonotonicTimestamp
    let source: IPAddress?
    let hopLimit: UInt8?

    init(
        bytes: [UInt8],
        receivedAt: MonotonicTimestamp,
        source: IPAddress? = nil,
        hopLimit: UInt8? = nil
    ) {
        self.bytes = bytes
        self.receivedAt = receivedAt
        self.source = source
        self.hopLimit = hopLimit
    }
}
