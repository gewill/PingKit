/// One event in a ping run: a matched reply, or the various ways a probe can fail.
public enum PingResponse: Sendable, Equatable {
    /// An echo request left the socket. While the run remains active, one
    /// terminal event follows for the same sequence, so UIs can show a
    /// pending row per probe and update it in place.
    ///
    /// Each sequence produces exactly one of two outcomes: a `.sent` followed
    /// by a terminal event (the socket accepted the probe), or a single
    /// `.sendFailed` with no `.sent` (the probe never left the socket).
    case sent(sequence: UInt16)
    /// The socket rejected the probe, so it never left the host — no `.sent`
    /// is emitted for this sequence. The run continues (a transient failure
    /// recovers on the next interval); `errno` is the underlying `send`
    /// error, or 0 if unavailable.
    case sendFailed(sequence: UInt16, errno: Int32)
    case reply(PingReply)
    case timeout(sequence: UInt16)
    /// The network returned Destination Unreachable (ICMPv4 type 3 or
    /// ICMPv6 type 1) for this probe. The two families number their codes
    /// differently; interpret `code` according to the address family the
    /// run resolved to.
    case unreachable(sequence: UInt16, code: UInt8)
    /// The network returned Time Exceeded (ICMPv4 type 11 or ICMPv6 type 3)
    /// for this probe.
    case timeExceeded(sequence: UInt16)
    /// IPv6 path MTU discovery reported a packet too large for the next hop.
    case packetTooBig(sequence: UInt16, mtu: UInt32)
    /// IPv6 reported an invalid field in the invoking packet.
    case parameterProblem(sequence: UInt16, code: UInt8, pointer: UInt32)
}

/// A successful echo reply.
public struct PingReply: Sendable, Equatable {
    public let sequence: UInt16
    public let roundTripTime: Duration
    /// IPv4 TTL or IPv6 hop limit; `nil` when it isn't available.
    public let timeToLive: UInt8?
    public let from: IPAddress
    /// Total ICMP message size (header + payload), matching what `ping(8)` prints.
    public let byteCount: Int

    public init(sequence: UInt16, roundTripTime: Duration, timeToLive: UInt8?, from: IPAddress, byteCount: Int) {
        self.sequence = sequence
        self.roundTripTime = roundTripTime
        self.timeToLive = timeToLive
        self.from = from
        self.byteCount = byteCount
    }
}
