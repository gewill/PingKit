/// One event in a ping run: a matched reply, or the various ways a probe can fail.
public enum PingResponse: Sendable, Equatable {
    case reply(PingReply)
    case timeout(sequence: UInt16)
    /// The network returned ICMP Destination Unreachable (type 3) for this probe.
    case unreachable(sequence: UInt16, code: UInt8)
    /// The network returned ICMP Time Exceeded (type 11) for this probe.
    case timeExceeded(sequence: UInt16)
}

/// A successful echo reply.
public struct PingReply: Sendable, Equatable {
    public let sequence: UInt16
    public let roundTripTime: Duration
    /// TTL of the reply's IP header; `nil` on platforms where it isn't available.
    public let timeToLive: UInt8?
    public let from: IPv4Endpoint
    /// Total ICMP message size (header + payload), matching what `ping(8)` prints.
    public let byteCount: Int

    public init(sequence: UInt16, roundTripTime: Duration, timeToLive: UInt8?, from: IPv4Endpoint, byteCount: Int) {
        self.sequence = sequence
        self.roundTripTime = roundTripTime
        self.timeToLive = timeToLive
        self.from = from
        self.byteCount = byteCount
    }
}
