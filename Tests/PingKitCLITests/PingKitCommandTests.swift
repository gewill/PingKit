import ArgumentParser
import PingKit
import Testing
@testable import PingKitCLI

@Suite struct PingKitCommandTests {
    @Test func parsesPingOptions() throws {
        let command = try Ping.parse([
            "example.com", "-6", "-c", "5", "-i", "0.25",
            "-W", "1.5", "-s", "32", "-m", "48",
        ])

        #expect(command.host == "example.com")
        #expect(command.addressFamily == .ipv6)
        #expect(command.count == 5)
        #expect(command.interval == 0.25)
        #expect(command.timeout == 1.5)
        #expect(command.payloadSize == 32)
        #expect(command.timeToLive == 48)
    }

    @Test func parsesTraceOptions() throws {
        let command = try Trace.parse([
            "example.com", "-4", "-m", "12", "-q", "2",
            "-W", "0.5", "-s", "24",
        ])

        #expect(command.host == "example.com")
        #expect(command.forceIPv4)
        #expect(command.maxHops == 12)
        #expect(command.probesPerHop == 2)
        #expect(command.timeout == 0.5)
        #expect(command.payloadSize == 24)
    }

    @Test func rejectsConflictingAddressFamilies() {
        #expect(throws: (any Error).self) {
            try Ping.parse(["example.com", "-4", "-6"])
        }
    }

    @Test func traceRejectsIPv6Literals() {
        #expect(throws: (any Error).self) {
            try Trace.parse(["::1"])
        }
    }

    @Test func rejectsOutOfRangeValues() {
        #expect(throws: (any Error).self) {
            try Ping.parse(["example.com", "-c", "0"])
        }
        #expect(throws: (any Error).self) {
            try Trace.parse(["example.com", "-m", "256"])
        }
    }

    @Test func dispatchesDefaultPingAndTraceSubcommands() async throws {
        let ping = try await PingKitCommand.asyncParseAsRoot(["example.com"])
        #expect(ping is Ping)

        let trace = try await PingKitCommand.asyncParseAsRoot(["trace", "example.com"])
        #expect(trace is Trace)
    }

    @Test func allSendFailuresExitWithStatusTwo() {
        let statistics = PingStatistics(
            transmitted: 0,
            received: 0,
            minRTT: nil,
            averageRTT: nil,
            maxRTT: nil,
            stddevRTT: nil)

        #expect(Ping.resolvedExitCode(
            current: 0,
            statistics: statistics,
            sawSendFailure: true) == 2)
    }
}
