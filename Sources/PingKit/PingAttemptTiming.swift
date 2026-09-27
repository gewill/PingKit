/// Timing captured at the local socket send boundary for one probe attempt.
///
/// This is not a kernel transmit timestamp or evidence that a remote target
/// received the request. It is independent of when a consumer receives the
/// corresponding ``PingResponse/sent(sequence:)`` or
/// ``PingResponse/sendFailed(sequence:errno:)`` event.
public struct PingAttemptTiming: Sendable, Equatable {
    /// One-based position among send attempts, including local send failures.
    public let attemptNumber: Int
    /// The 16-bit wire sequence. `attemptNumber` disambiguates wraparound.
    public let sequence: UInt16
    /// Monotonic send-attempt boundary on the same `ContinuousClock` timeline
    /// as ``PingConfiguration/sendDeadline``. A caller can compare this with
    /// its own session start to account for delay before the first attempt.
    public let instant: ContinuousClock.Instant
    /// Time since the previous attempt at the same socket boundary.
    /// `nil` for the first attempt.
    public let intervalSincePreviousAttempt: Duration?

    init(attemptNumber: Int, sequence: UInt16, instant: ContinuousClock.Instant,
         intervalSincePreviousAttempt: Duration?) {
        self.attemptNumber = attemptNumber
        self.sequence = sequence
        self.instant = instant
        self.intervalSincePreviousAttempt = intervalSincePreviousAttempt
    }
}
