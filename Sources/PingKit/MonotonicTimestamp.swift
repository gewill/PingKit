#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A monotonic point in time with nanosecond resolution, used for RTT
/// measurement.
///
/// All timestamps in one process share a clock base — `CLOCK_UPTIME_RAW`
/// (the `mach_absolute_time` clock) on Darwin, `CLOCK_MONOTONIC` on Linux —
/// so kernel receive timestamps delivered via socket control messages can be
/// subtracted directly from userspace send timestamps.
struct MonotonicTimestamp: Sendable, Equatable, Comparable {
    let nanoseconds: UInt64

    init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    static func now() -> MonotonicTimestamp {
        #if canImport(Darwin)
        return MonotonicTimestamp(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        #else
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return MonotonicTimestamp(nanoseconds: UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec))
        #endif
    }

    #if canImport(Darwin)
    static func fromMachAbsoluteTime(_ ticks: UInt64) -> MonotonicTimestamp {
        MonotonicTimestamp(
            nanoseconds: ticks * UInt64(timebase.numer) / UInt64(timebase.denom))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    #endif

    /// The elapsed time since `earlier`, clamped to zero if the clocks
    /// disagree by a hair.
    func duration(since earlier: MonotonicTimestamp) -> Duration {
        guard nanoseconds > earlier.nanoseconds else { return .zero }
        return .nanoseconds(nanoseconds - earlier.nanoseconds)
    }

    static func < (lhs: MonotonicTimestamp, rhs: MonotonicTimestamp) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}
