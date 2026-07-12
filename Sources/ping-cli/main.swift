import Dispatch
import Foundation
import PingKit

func usage() -> Never {
    print("""
    usage: ping-cli <host> [-c count] [-i interval_seconds] [-W timeout_seconds] [-s payload_bytes]
    """)
    exit(64)
}

func milliseconds(_ duration: Duration) -> String {
    let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    return String(format: "%.3f", seconds * 1000)
}

var host: String?
var count: Int?
var intervalSeconds = 1.0
var timeoutSeconds = 2.0
var payloadSize = 56

var arguments = CommandLine.arguments.dropFirst().makeIterator()
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

let configuration = PingConfiguration(
    interval: .seconds(intervalSeconds),
    timeout: .seconds(timeoutSeconds),
    count: count.map { .times($0) } ?? .unlimited,
    payloadSize: payloadSize)

let pinger = Pinger(host: host, configuration: configuration)

signal(SIGINT, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue(label: "ping-cli.sigint"))
interruptSource.setEventHandler {
    Task { await pinger.stop() }
}
interruptSource.activate()

print("PING \(host): \(payloadSize) data bytes")

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
