import PingKit
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var host = "8.8.8.8"
    @State private var lines: [Line] = []
    @State private var summary = ""
    @State private var pingTask: Task<Void, Never>?

    private var isRunning: Bool { pingTask != nil }

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
                }
                .padding(.horizontal)

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
                lines.append(Line(text: "— stopped: app entered background —", isError: true))
                stop()
            }
        }
    }

    private struct Line: Identifiable {
        let id = UUID()
        let text: String
        var isError = false
    }

    private func start() {
        lines = []
        summary = ""
        let pinger = Pinger(host: host)
        pingTask = Task {
            do {
                for try await response in pinger.responses {
                    append(response)
                }
            } catch {
                lines.append(Line(text: "error: \(error)", isError: true))
            }
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
        case .reply(let reply):
            let ttl = reply.timeToLive.map(String.init) ?? "?"
            lines.append(Line(text: "seq=\(reply.sequence) ttl=\(ttl) time=\(Self.milliseconds(reply.roundTripTime)) ms"))
        case .timeout(let sequence):
            lines.append(Line(text: "seq=\(sequence) timed out", isError: true))
        case .unreachable(let sequence, let code):
            lines.append(Line(text: "seq=\(sequence) unreachable (code \(code))", isError: true))
        case .timeExceeded(let sequence):
            lines.append(Line(text: "seq=\(sequence) TTL exceeded", isError: true))
        }
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
