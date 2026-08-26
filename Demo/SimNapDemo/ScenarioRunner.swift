import Foundation
import Network
import SimulatorNetworkCore

/// Headless scenario runner driven by the `SIMNAP_SCENARIO` environment
/// variable (set via `SIMCTL_CHILD_SIMNAP_SCENARIO` when spawning the app
/// binary). Prints one structured `SIMNAP_RESULT {...}` JSON line to stdout
/// and exits — lets a host-side script drive real cold launches, offline
/// transitions, and in-flight cancellation without simulating taps.
enum ScenarioRunner {
    static func runIfRequested() {
        guard let scenario = ProcessInfo.processInfo.environment["SIMNAP_SCENARIO"] else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        Task {
            await run(scenario)
            exit(0)
        }
    }

    private static func run(_ scenario: String) async {
        let client = RequestClient()

        switch scenario {
        case "state":
            emit(["scenario": "state", "state": describe(SimulatorNetwork.state)])

        case "quick":
            let outcome = await client.perform(client.integratedSession, url: URL(string: "https://httpbin.org/get")!)
            emit(payload(scenario: "quick", outcome: outcome, extra: ["stateAtStart": describe(SimulatorNetwork.state)]))

        case "headers":
            var request = URLRequest(url: URL(string: "https://httpbin.org/headers")!)
            request.setValue("scenario-marker", forHTTPHeaderField: "X-SimNap-Test")
            let start = Date()
            do {
                let (data, response) = try await client.integratedSession.data(for: request)
                let elapsed = Date().timeIntervalSince(start)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                let echoed = body.contains("scenario-marker")
                emit([
                    "scenario": "headers", "outcome": "success", "status": status,
                    "headerEchoed": echoed, "elapsedMs": Int(elapsed * 1000)
                ])
            } catch {
                emit(["scenario": "headers", "outcome": "failure", "error": describeError(error)])
            }

        case "redirect":
            let outcome = await client.perform(client.integratedSession, url: URL(string: "https://httpbin.org/redirect/1")!)
            emit(payload(scenario: "redirect", outcome: outcome, extra: [:]))

        case "unintegrated":
            // Deliberately bypasses SimulatorNetwork — must succeed even while offline.
            let outcome = await client.perform(client.plainSession, url: URL(string: "https://httpbin.org/get")!)
            emit(payload(scenario: "unintegrated", outcome: outcome, extra: ["stateAtStart": describe(SimulatorNetwork.state)]))

        case "network-framework":
            await runNetworkFrameworkProbe()

        case "delayed-watch":
            // Prints SIMNAP_READY the instant the request is in flight so the
            // harness can trigger an offline transition mid-request, then
            // reports how the request actually resolved.
            print("SIMNAP_READY")
            let outcome = await client.perform(client.integratedSession, url: URL(string: "https://httpbin.org/delay/6")!)
            emit(payload(scenario: "delayed-watch", outcome: outcome, extra: [:]))

        default:
            emit(["scenario": scenario, "outcome": "failure", "error": "unknown-scenario"])
        }
    }

    private static func runNetworkFrameworkProbe() async {
        await withCheckedContinuation { continuation in
            let start = Date()
            var resumed = false
            let connection = NWConnection(host: "www.apple.com", port: 443, using: .tls)
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    let elapsed = Date().timeIntervalSince(start)
                    emit(["scenario": "network-framework", "outcome": "success", "elapsedMs": Int(elapsed * 1000)])
                    connection.cancel()
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    emit(["scenario": "network-framework", "outcome": "failure", "error": "\(error)"])
                    connection.cancel()
                    continuation.resume()
                default:
                    break
                }
            }
            connection.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard !resumed else { return }
                resumed = true
                emit(["scenario": "network-framework", "outcome": "failure", "error": "timeout"])
                connection.cancel()
                continuation.resume()
            }
        }
    }

    private static func payload(scenario: String, outcome: RequestOutcome, extra: [String: Any]) -> [String: Any] {
        var result: [String: Any] = ["scenario": scenario]
        result.merge(extra) { current, _ in current }
        switch outcome {
        case .success(let status, let bytes, let elapsed):
            result["outcome"] = "success"
            result["status"] = status
            result["bytes"] = bytes
            result["elapsedMs"] = Int(elapsed * 1000)
        case .failure(let code, let elapsed):
            result["outcome"] = "failure"
            result["error"] = code
            result["elapsedMs"] = Int(elapsed * 1000)
        }
        return result
    }

    private static func describe(_ state: SimulatorNetworkState) -> String {
        switch state {
        case .online: return "online"
        case .offline(let error): return "offline:\(error.rawValue)"
        }
    }

    private static func describeError(_ error: Error) -> String {
        (error as? URLError)?.code.description ?? error.localizedDescription
    }

    private static func emit(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        print("SIMNAP_RESULT \(json)")
    }
}
