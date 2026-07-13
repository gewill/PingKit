import Dispatch
import Foundation
import PingKit

func usage() -> Never {
    print("""
    usage: ping-cli <host> [-c count] [-i interval_seconds] [-W timeout_seconds] [-s payload_bytes]
           ping-cli trace <host> [-m max_hops] [-q probes_per_hop] [-W timeout_seconds]
    """)
    exit(64)
}

func milliseconds(_ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    return String(format: "%.3f", seconds * 1000)
}

var argumentList = Array(CommandLine.arguments.dropFirst())
let traceMode = argumentList.first == "trace"
if traceMode { argumentList.removeFirst() }

var host: String?
var count: Int?
var intervalSeconds = 1.0
var timeoutSeconds: Double?
var payloadSize: Int?
var maxHops = 30
var probesPerHop = 3

var arguments = argumentList.makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "-c":
        guard let value = arguments.next(), let parsed = Int(value), parsed > 0 else { usage() }
        count = parsed
    case "-i":
        guard let value = arguments.next(), let parsed = Double(value), parsed > 0 else { usage() }
        intervalSeconds = parsed
    case "-W":
        guard let value = arguments.next(), let parsed = Double(value), parsed > 0 else { usage() }
        timeoutSeconds = parsed
    case "-s":
        guard let value = arguments.next(), let parsed = Int(value), (0...65_507).contains(parsed) else { usage() }
        payloadSize = parsed
    case "-m":
        guard let value = arguments.next(), let parsed = Int(value), (1...255).contains(parsed) else { usage() }
        maxHops = parsed
    case "-q":
        guard let value = arguments.next(), let parsed = Int(value), (1...16).contains(parsed) else { usage() }
        probesPerHop = parsed
    case "-h", "--help":
        usage()
    default:
        if host == nil, !argument.hasPrefix("-") {
            host = argument
        } else {
            usage()
        }
    }
}

guard let host else { usage() }

signal(SIGINT, SIG_IGN)
let interruptQueue = DispatchQueue(label: "ping-cli.sigint")

if traceMode {
    let configuration = TracerouteConfiguration(
        maxHops: maxHops,
        probesPerHop: probesPerHop,
        timeout: .seconds(timeoutSeconds ?? 1.0),
        payloadSize: payloadSize ?? 16)
    let tracer = Tracer(host: host, configuration: configuration)

    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: interruptQueue)
    interruptSource.setEventHandler {
        Task { await tracer.stop() }
    }
    interruptSource.activate()

    print("traceroute to \(host), \(maxHops) hops max")
    var reached = false
    do {
        for try await hop in tracer.hops {
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
            print(String(format: "%2d  ", hop.ttl) + parts.joined(separator: "  "))
            if hop.reachedDestination { reached = true }
        }
    } catch {
        print("ping-cli: \(error)")
        exit(2)
    }
    exit(reached ? 0 : 1)
}

let configuration = PingConfiguration(
    interval: .seconds(intervalSeconds),
    timeout: .seconds(timeoutSeconds ?? 2.0),
    count: count.map { .times($0) } ?? .unlimited,
    payloadSize: payloadSize ?? 56)

let pinger = Pinger(host: host, configuration: configuration)

let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: interruptQueue)
interruptSource.setEventHandler {
    Task { await pinger.stop() }
}
interruptSource.activate()

print("PING \(host): \(configuration.payloadSize) data bytes")

var exitCode: Int32 = 0
do {
    for try await response in pinger.responses {
        switch response {
        case .reply(let reply):
            let ttl = reply.timeToLive.map(String.init) ?? "?"
            print("\(reply.byteCount) bytes from \(reply.from): icmp_seq=\(reply.sequence) ttl=\(ttl) time=\(milliseconds(reply.roundTripTime)) ms")
        case .timeout(let sequence):
            print("Request timeout for icmp_seq \(sequence)")
        case .unreachable(let sequence, let code):
            print("Destination unreachable for icmp_seq \(sequence) (ICMP code \(code))")
        case .timeExceeded(let sequence):
            print("Time to live exceeded for icmp_seq \(sequence)")
        }
    }
} catch {
    print("ping-cli: \(error)")
    exitCode = 2
}

let statistics = await pinger.statistics()
print("\n--- \(host) ping statistics ---")
let lossPercent = String(format: "%.1f", statistics.lossRate * 100)
print("\(statistics.transmitted) packets transmitted, \(statistics.received) packets received, \(lossPercent)% packet loss")
if let minimum = statistics.minRTT, let average = statistics.averageRTT,
   let maximum = statistics.maxRTT, let stddev = statistics.stddevRTT {
    print("round-trip min/avg/max/stddev = \(milliseconds(minimum))/\(milliseconds(average))/\(milliseconds(maximum))/\(milliseconds(stddev)) ms")
}
if statistics.received == 0 && statistics.transmitted > 0 {
    exitCode = 2
}
exit(exitCode)
