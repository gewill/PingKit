import PingKit
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var host = "8.8.8.8"
    @State private var family: Family = .automatic
    @State private var lines: [Line] = []
    @State private var pending: [UInt16: UUID] = [:]
    @State private var summary = ""
    @State private var pingTask: Task<Void, Never>?

    private var isRunning: Bool { pingTask != nil }

    /// Dual-stack hosts (A + AAAA records) handy for exercising IPv6 and
    /// NAT64 resolution.
    private static let presetHosts = ["google.com", "bing.com", "taobao.com", "www.qq.com"]

    /// UI-facing mirror of `PingConfiguration.AddressFamily`, made
    /// `CaseIterable` so it can drive a `Picker`.
    private enum Family: String, CaseIterable, Identifiable {
        case automatic = "Auto"
        case ipv4 = "IPv4"
        case ipv6 = "IPv6"

        var id: Self { self }

        var addressFamily: PingConfiguration.AddressFamily {
            switch self {
            case .automatic: .automatic
            case .ipv4: .ipv4
            case .ipv6: .ipv6
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField("Host or IP", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .disabled(isRunning)
                    Button(isRunning ? "Stop" : "Start") {
                        isRunning ? stop() : start()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isRunning ? .red : .accentColor)
                }
                .padding(.horizontal)

                // Auto follows system DNS ordering (DNS64/NAT64); force
                // IPv4/IPv6 to test a specific stack on the current network.
                Picker("Address family", selection: $family) {
                    ForEach(Family.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(isRunning)
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.presetHosts, id: \.self) { preset in
                            Button(preset) { host = preset }
                                .buttonStyle(.bordered)
                                .disabled(isRunning)
                        }
                    }
                    .padding(.horizontal)
                }

                List(lines) { line in
                    Text(line.text)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(line.isError ? .red : .primary)
                }
                .listStyle(.plain)

                if !summary.isEmpty {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("PingKit Demo")
        }
        // Suspended apps can be terminated by iOS at any time, so a ping
        // session must not expect to survive the background. Stop cleanly
        // when leaving the foreground; the user restarts on return.
        .onChange(of: scenePhase) { phase in
            if phase == .background, isRunning {
                prepend(Line(text: "— stopped: app entered background —", isError: true))
                stop()
            }
        }
    }

    private struct Line: Identifiable {
        let id = UUID()
        var text: String
        var isError = false
    }

    private func start() {
        lines = []
        pending = [:]
        summary = ""
        let pinger = Pinger(host: host, configuration: .init(addressFamily: family.addressFamily))
        pingTask = Task {
            do {
                for try await response in pinger.responses {
                    append(response)
                }
            } catch {
                prepend(Line(text: "error: \(error)", isError: true))
            }
            finishPending()
            let stats = await pinger.statistics()
            summary = Self.format(stats)
            pingTask = nil
        }
    }

    private func stop() {
        pingTask?.cancel()
    }

    private func append(_ response: PingResponse) {
        switch response {
        case .sent(let sequence):
            let line = Line(text: "seq=\(sequence) pinging …")
            pending[sequence] = line.id
            prepend(line)
        case .reply(let reply):
            let ttl = reply.timeToLive.map(String.init) ?? "?"
            // Show the source address so it's clear which family actually
            // resolved — on NAT64, "Auto" against an IPv4 literal comes back
            // from a synthesized IPv6 source.
            resolve(reply.sequence, text: "seq=\(reply.sequence) from \(reply.from) ttl=\(ttl) time=\(Self.milliseconds(reply.roundTripTime)) ms")
        case .timeout(let sequence):
            resolve(sequence, text: "seq=\(sequence) timed out", isError: true)
        case .unreachable(let sequence, let code):
            resolve(sequence, text: "seq=\(sequence) unreachable (code \(code))", isError: true)
        case .timeExceeded(let sequence):
            resolve(sequence, text: "seq=\(sequence) TTL exceeded", isError: true)
        case .packetTooBig(let sequence, let mtu):
            resolve(sequence, text: "seq=\(sequence) packet too big (MTU \(mtu))", isError: true)
        case .parameterProblem(let sequence, let code, let pointer):
            resolve(
                sequence,
                text: "seq=\(sequence) parameter problem (code \(code), pointer \(pointer))",
                isError: true)
        }
    }

    /// Updates the pending row inserted by `.sent` in place, keeping its
    /// position and identity; falls back to prepending if it's gone.
    private func resolve(_ sequence: UInt16, text: String, isError: Bool = false) {
        if let id = pending.removeValue(forKey: sequence),
           let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index].text = text
            lines[index].isError = isError
        } else {
            prepend(Line(text: text, isError: isError))
        }
    }

    private func finishPending() {
        for sequence in Array(pending.keys) {
            resolve(sequence, text: "seq=\(sequence) stopped", isError: true)
        }
    }

    /// Newest entries go on top so a long run never needs manual scrolling.
    private func prepend(_ line: Line) {
        lines.insert(line, at: 0)
    }

    private static func format(_ stats: PingStatistics) -> String {
        var text = "\(stats.transmitted) sent, \(stats.received) received, \(Int(stats.lossRate * 100))% loss"
        if let average = stats.averageRTT {
            text += ", avg \(milliseconds(average)) ms"
        }
        return text
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
        return String(format: "%.1f", seconds * 1000)
    }
}
