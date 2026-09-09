/// Maximum queued items in a ping or traceroute run.
///
/// Both limits must be positive. Exceeding either ends the run with
/// ``PingError/bufferOverflow(buffer:capacity:)``. Already buffered public
/// events drain in order before the error; outstanding probes are cancelled.
/// A slow consumer does not change the configured probing cadence.
public struct PingBufferLimits: Sendable, Equatable {
    /// Public ping events or traceroute hops waiting for their consumer.
    public var events: Int
    /// Raw datagrams waiting for the actor. Each can contain up to 65,535 bytes.
    public var receivedDatagrams: Int

    /// Defaults allow 1,024 public events and 256 received datagrams.
    /// The raw queue therefore holds at most about 16 MiB of packet bytes;
    /// ordinary echo replies require much less.
    public init(events: Int = 1_024, receivedDatagrams: Int = 256) {
        self.events = events
        self.receivedDatagrams = receivedDatagrams
    }

    var isValid: Bool { events > 0 && receivedDatagrams > 0 }
}
