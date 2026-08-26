import SwiftUI
import SimulatorNetworkCore

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let title: String
    let detail: String
    let isError: Bool
}

@MainActor
final class DemoViewModel: ObservableObject {
    @Published private(set) var state: SimulatorNetworkState = .online
    @Published private(set) var entries: [LogEntry] = []
    @Published private(set) var inFlightDelayed = false

    private let client = RequestClient()

    private var observationTask: Task<Void, Never>?
    private var delayedTask: Task<Void, Never>?

    func start() {
        observationTask = Task {
            for await state in SimulatorNetwork.states {
                self.state = state
            }
        }
    }

    func sendQuickRequest() {
        Task {
            await runRequest(
                title: "GET httpbin.org/get",
                url: URL(string: "https://httpbin.org/get")!
            )
        }
    }

    /// Long enough to still be in flight when you flip the Simulator offline
    /// from the CLI or menu bar — exercises exactly-once cancellation.
    func sendDelayedRequest() {
        delayedTask?.cancel()
        inFlightDelayed = true
        delayedTask = Task {
            await runRequest(
                title: "GET httpbin.org/delay/6",
                url: URL(string: "https://httpbin.org/delay/6")!
            )
            inFlightDelayed = false
        }
    }

    func clearLog() {
        entries.removeAll()
    }

    private func runRequest(title: String, url: URL) async {
        let start = Date()
        switch await client.perform(client.integratedSession, url: url) {
        case .success(let status, _, let elapsed):
            append(LogEntry(
                timestamp: start,
                title: title,
                detail: String(format: "HTTP %d in %.2fs", status, elapsed),
                isError: false
            ))
        case .failure(let code, let elapsed):
            append(LogEntry(
                timestamp: start,
                title: title,
                detail: String(format: "URLError.%@ after %.2fs", code, elapsed),
                isError: true
            ))
        }
    }

    private func append(_ entry: LogEntry) {
        entries.insert(entry, at: 0)
    }
}

struct ContentView: View {
    @StateObject private var model = DemoViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                stateBadge

                VStack(spacing: 10) {
                    Button("Send Quick Request") { model.sendQuickRequest() }
                        .buttonStyle(.borderedProminent)

                    Button(model.inFlightDelayed ? "6s Request In Flight…" : "Send 6s Request") {
                        model.sendDelayedRequest()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.inFlightDelayed)

                    Text("Toggle the Simulator offline from the CLI or menu bar while the 6s request is in flight to see it cancel immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Divider()

                HStack {
                    Text("Request Log").font(.headline)
                    Spacer()
                    Button("Clear", action: model.clearLog)
                        .font(.caption)
                }
                .padding(.horizontal)

                List(model.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.subheadline.bold())
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(entry.isError ? .red : .green)
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
            .padding(.top)
            .navigationTitle("SimNap Demo")
        }
        .navigationViewStyle(.stack)
        .onAppear { model.start() }
    }

    private var stateBadge: some View {
        let (label, color): (String, Color) = {
            switch model.state {
            case .online:
                return ("ONLINE", .green)
            case .offline(let error):
                return ("OFFLINE — \(error.rawValue)", .red)
            }
        }()

        return Text(label)
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
