import ArgumentParser
import Dispatch
import Foundation
import PingKit

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public struct PingKitCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "pingkit",
        abstract: "Send ICMP echo requests over IPv4 or IPv6.",
        subcommands: [Ping.self, Trace.self],
        defaultSubcommand: Ping.self)

    public init() {}
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public struct Ping: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ping",
        abstract: "Send ICMP echo requests over IPv4 or IPv6.")

    @Argument(help: "Host name or IP address to ping.")
    var host: String

    @Flag(name: [.customShort("4"), .customLong("ipv4")], help: "Use IPv4 only.")
    var forceIPv4 = false

    @Flag(name: [.customShort("6"), .customLong("ipv6")], help: "Use IPv6 only.")
    var forceIPv6 = false

    @Option(name: [.customShort("c"), .long], help: "Stop after this many probes.")
    var count: Int?

    @Option(name: [.customShort("i"), .long], help: "Seconds between probes.")
    var interval = 1.0

    @Option(name: [.customShort("W"), .customLong("timeout")], help: "Reply timeout in seconds.")
    var timeout = 2.0

    @Option(name: [.customShort("s"), .customLong("payload-size")], help: "ICMP payload size in bytes.")
    var payloadSize = 56

    @Option(name: [.customShort("m"), .customLong("ttl")], help: "IPv4 TTL or IPv6 hop limit (1...255).")
    var timeToLive: Int?

    public init() {}

    public mutating func validate() throws {
        if forceIPv4 && forceIPv6 {
            throw ValidationError("-4/--ipv4 and -6/--ipv6 are mutually exclusive")
        }
        if let count, count <= 0 {
            throw ValidationError("--count must be greater than zero")
        }
        guard interval > 0 else { throw ValidationError("--interval must be greater than zero") }
        guard timeout > 0 else { throw ValidationError("--timeout must be greater than zero") }
        guard (0...65_507).contains(payloadSize) else {
            throw ValidationError("--payload-size must be between 0 and 65507")
        }
        if let timeToLive, !(1...255).contains(timeToLive) {
            throw ValidationError("--ttl must be between 1 and 255")
        }
    }

    public mutating func run() async throws {
        let configuration = PingConfiguration(
            interval: .seconds(interval),
            timeout: .seconds(timeout),
            count: count.map { .times($0) } ?? .unlimited,
            payloadSize: payloadSize,
            timeToLive: timeToLive,
            addressFamily: addressFamily)
        let pinger = Pinger(host: host, configuration: configuration)
        let interruptSource = makeInterruptSource { await pinger.stop() }
        defer { interruptSource.cancel() }

        print("PING \(host): \(configuration.payloadSize) data bytes")

        var exitCode: Int32 = 0
        do {
            for try await response in pinger.responses {
                print(response)
            }
        } catch {
            print("pingkit: \(error)")
            exitCode = 2
        }

        let statistics = await pinger.statistics()
        printStatistics(statistics, host: host)
        if statistics.received == 0 && statistics.transmitted > 0 {
            exitCode = 2
        }
        if exitCode != 0 { throw ExitCode(exitCode) }
    }

    var addressFamily: PingConfiguration.AddressFamily {
        if forceIPv4 { return .ipv4 }
        if forceIPv6 { return .ipv6 }
        return .automatic
    }
}

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
public struct Trace: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "trace",
        abstract: "Trace the IPv4 route to a host.")

    @Argument(help: "Host name or IPv4 address to trace.")
    var host: String

    @Flag(name: [.customShort("4"), .customLong("ipv4")], help: "Use IPv4 (the only supported trace family).")
    var forceIPv4 = false

    @Option(name: [.customShort("m"), .customLong("max-hops")], help: "Maximum hop count (1...255).")
    var maxHops = 30

    @Option(name: [.customShort("q"), .customLong("queries")], help: "Probes per hop (1...16).")
    var probesPerHop = 3

    @Option(name: [.customShort("W"), .customLong("timeout")], help: "Probe timeout in seconds.")
    var timeout = 1.0

    @Option(name: [.customShort("s"), .customLong("payload-size")], help: "ICMP payload size in bytes.")
    var payloadSize = 16

    public init() {}

    public mutating func validate() throws {
        // Hostnames can't contain colons, so this catches IPv6 literals.
        guard !host.contains(":") else {
            throw ValidationError("trace supports IPv4 hosts only")
        }
        guard (1...255).contains(maxHops) else {
            throw ValidationError("--max-hops must be between 1 and 255")
        }
        guard (1...16).contains(probesPerHop) else {
            throw ValidationError("--queries must be between 1 and 16")
        }
        guard timeout > 0 else { throw ValidationError("--timeout must be greater than zero") }
        guard (0...65_507).contains(payloadSize) else {
            throw ValidationError("--payload-size must be between 0 and 65507")
        }
    }

    public mutating func run() async throws {
        let configuration = TracerouteConfiguration(
            maxHops: maxHops,
            probesPerHop: probesPerHop,
            timeout: .seconds(timeout),
            payloadSize: payloadSize)
        let tracer = Tracer(host: host, configuration: configuration)
        let interruptSource = makeInterruptSource { await tracer.stop() }
        defer { interruptSource.cancel() }

        print("traceroute to \(host), \(maxHops) hops max")
        var reached = false
        do {
            for try await hop in tracer.hops {
                print(hop)
                if hop.reachedDestination { reached = true }
            }
        } catch {
            print("pingkit: \(error)")
            throw ExitCode(2)
        }
        if !reached { throw ExitCode.failure }
    }
}

private func makeInterruptSource(
    stop: @escaping @Sendable () async -> Void
) -> any DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let queue = DispatchQueue(label: "pingkit.sigint")
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
    source.setEventHandler { Task { await stop() } }
    source.activate()
    return source
}

private func print(_ response: PingResponse) {
    switch response {
    case .sent:
        break
    case .reply(let reply):
        let ttl = reply.timeToLive.map(String.init) ?? "?"
        Swift.print(
            "\(reply.byteCount) bytes from \(reply.from): icmp_seq=\(reply.sequence) "
                + "ttl=\(ttl) time=\(milliseconds(reply.roundTripTime)) ms")
    case .timeout(let sequence):
        Swift.print("Request timeout for icmp_seq \(sequence)")
    case .unreachable(let sequence, let code):
        Swift.print("Destination unreachable for icmp_seq \(sequence) (ICMP code \(code))")
    case .timeExceeded(let sequence):
        Swift.print("Time to live exceeded for icmp_seq \(sequence)")
    case .packetTooBig(let sequence, let mtu):
        Swift.print("Packet too big for icmp_seq \(sequence) (MTU \(mtu))")
    case .parameterProblem(let sequence, let code, let pointer):
        Swift.print("Parameter problem for icmp_seq \(sequence) (code \(code), pointer \(pointer))")
    }
}

private func print(_ hop: TracerouteHop) {
    var parts: [String] = []
    var lastRouter: IPv4Endpoint?
    for probe in hop.probes {
        switch probe {
        case .response(let router, let rtt, let kind):
            var entry = router == lastRouter ? "" : "\(router)  "
            lastRouter = router
            entry += "\(milliseconds(rtt)) ms"
            if case .unreachable(let code) = kind { entry += " !\(code)" }
            parts.append(entry)
        case .timeout:
            parts.append("*")
        }
    }
    Swift.print(String(format: "%2d  ", hop.ttl) + parts.joined(separator: "  "))
}

private func printStatistics(_ statistics: PingStatistics, host: String) {
    Swift.print("\n--- \(host) ping statistics ---")
    let lossPercent = String(format: "%.1f", statistics.lossRate * 100)
    Swift.print(
        "\(statistics.transmitted) packets transmitted, \(statistics.received) packets received, "
            + "\(lossPercent)% packet loss")
    if let minimum = statistics.minRTT, let average = statistics.averageRTT,
       let maximum = statistics.maxRTT, let stddev = statistics.stddevRTT {
        Swift.print(
            "round-trip min/avg/max/stddev = \(milliseconds(minimum))/\(milliseconds(average))/"
                + "\(milliseconds(maximum))/\(milliseconds(stddev)) ms")
    }
}

private func milliseconds(_ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds)
        + Double(duration.components.attoseconds) * 1e-18
    return String(format: "%.3f", seconds * 1000)
}
