/// Abstraction over the ICMP socket so `Pinger`'s state machine can be tested
/// with a mock that injects replies, timeouts, and error packets.
protocol PingSocket: Sendable {
    /// Starts receiving. `receiveHandler` is invoked on an arbitrary internal
    /// queue with each raw datagram and its receive timestamp — the kernel's
    /// arrival timestamp where the platform provides one, otherwise the
    /// instant the datagram was read.
    func activate(receiveHandler: @escaping @Sendable ([UInt8], MonotonicTimestamp) -> Void) throws

    /// Sends one ICMP datagram to the destination the socket was created for.
    func send(_ datagram: [UInt8]) throws

    /// Sets the IPv4 TTL applied to subsequently sent datagrams
    /// (traceroute-style probing).
    func setTimeToLive(_ ttl: Int) throws

    /// Stops receiving and releases the descriptor. Idempotent.
    func close()
}

struct SocketDatagram: Sendable {
    let bytes: [UInt8]
    let receivedAt: MonotonicTimestamp
}
