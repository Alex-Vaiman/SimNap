import Foundation
import Network
import SimulatorNetworkCore

/// Headless scenario runner driven by the `SIMNAP_SCENARIO` environment
/// variable (set via `SIMCTL_CHILD_SIMNAP_SCENARIO` when spawning the app
/// binary). Prints one structured `SIMNAP_RESULT {...}` JSON line to stdout
/// and exits — lets a host-side script drive real cold launches, offline
/// transitions, and request-admission boundaries without simulating taps.
enum ScenarioRunner {
    static func runIfRequested() {
        guard let scenario = ProcessInfo.processInfo.environment["SIMNAP_SCENARIO"] else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        Task {
            await run(scenario)
            exit(0)
        }
    }

    /// Every scenario this binary implements. Reported by the `capabilities`
    /// scenario so a harness can verify the *installed* app supports what it is
    /// about to run — checking the local source instead would happily pass
    /// against a stale install.
    private static let supportedScenarios = [
        "capabilities", "state", "state-watch", "quick", "stop", "stop-start",
        "post-online", "post-offline", "start-only", "start-later", "coexistence", "coexistence-reversed", "shared-session", "headers", "redirect", "unintegrated",
        "network-framework", "delayed-watch",
        "reachability", "reachability-watch", "reachability-probe-off", "reachability-probe-toggle",
        "reachability-probe-gate-silence"
    ]

    private static func run(_ scenario: String) async {
        let client = RequestClient()

        switch scenario {
        case "capabilities":
            emit(["scenario": "capabilities", "scenarios": supportedScenarios])

        case "state":
            emit(["scenario": "state", "state": describe(SimulatorNetwork.state)])

        case "state-watch":
            let initialState = describe(SimulatorNetwork.state)
            print("SIMNAP_READY")
            for await state in SimulatorNetwork.states {
                let nextState = describe(state)
                guard nextState != initialState else { continue }
                emit([
                    "scenario": "state-watch",
                    "initialState": initialState,
                    "state": nextState
                ])
                return
            }

        case "quick":
            let outcome = await client.perform(client.integratedSession, url: URL(string: "https://httpbin.org/get")!)
            emit(payload(scenario: "quick", outcome: outcome, extra: ["stateAtStart": describe(SimulatorNetwork.state)]))

        case "stop":
            let stateBeforeStop = describe(SimulatorNetwork.state)
            SimulatorNetwork.stop()
            let outcome = await client.perform(client.integratedSession, url: URL(string: "https://httpbin.org/get")!)
            emit(payload(
                scenario: "stop",
                outcome: outcome,
                extra: [
                    "stateBeforeStop": stateBeforeStop,
                    "stateAfterStop": describe(SimulatorNetwork.state)
                ]
            ))

        // A POST with a body is the sharpest check that online traffic is
        // untouched. Anything that re-sent the request would have to carry the
        // body across itself, and `URLProtocol` loses body streams.
        case "post-online":
            let marker = "simnap-body-marker-42"
            var request = URLRequest(url: URL(string: "https://httpbin.org/post")!)
            request.httpMethod = "POST"
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(marker.utf8)
            let start = Date()
            do {
                let (data, response) = try await client.integratedSession.data(for: request)
                let elapsed = Date().timeIntervalSince(start)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let echoed = (String(data: data, encoding: .utf8) ?? "").contains(marker)
                emit([
                    "scenario": "post-online", "outcome": "success", "status": status,
                    "bodyEchoed": echoed, "elapsedMs": Int(elapsed * 1000)
                ])
            } catch {
                emit(["scenario": "post-online", "outcome": "failure", "error": describeError(error)])
            }

        case "post-offline":
            var request = URLRequest(url: URL(string: "https://httpbin.org/post")!)
            request.httpMethod = "POST"
            request.httpBody = Data("simnap-body-marker-42".utf8)
            let outcome = await client.perform(client.integratedSession, request: request)
            emit(payload(scenario: "post-offline", outcome: outcome, extra: [
                "stateAtStart": describe(SimulatorNetwork.state)
            ]))

        // stop() must leave pass-through, and an explicit start() must
        // reconcile persisted truth again even though the record is unchanged.
        case "stop-start":
            let beforeStop = describe(SimulatorNetwork.state)
            SimulatorNetwork.stop()
            let stoppedState = describe(SimulatorNetwork.state)
            let stoppedOutcome = await client.perform(
                client.integratedSession,
                url: URL(string: "https://httpbin.org/get")!
            )
            SimulatorNetwork.start()
            let restartedState = describe(SimulatorNetwork.state)
            let restartedOutcome = await client.perform(
                client.integratedSession,
                url: URL(string: "https://httpbin.org/get")!
            )
            emit([
                "scenario": "stop-start",
                "beforeStop": beforeStop,
                "stoppedState": stoppedState,
                "stoppedOutcome": outcomeLabel(stoppedOutcome),
                "restartedState": restartedState,
                "restartedOutcome": outcomeLabel(restartedOutcome),
                "restartedError": errorLabel(restartedOutcome)
            ])

        // The point of start(): a session built the ordinary way, with no
        // SimNap call anywhere near it, must still be gated.
        case "start-only":
            SimulatorNetwork.start()
            let plain = URLSession(configuration: .default)
            let gated = await client.perform(plain, url: URL(string: "https://httpbin.org/get")!)

            SimulatorNetwork.stop()
            let afterStop = URLSession(configuration: .default)
            let released = await client.perform(afterStop, url: URL(string: "https://httpbin.org/get")!)

            emit([
                "scenario": "start-only",
                "afterStart": outcomeLabel(gated),
                "afterStartError": errorLabel(gated),
                "afterStop": outcomeLabel(released)
            ])

        // start() has no ordering requirement: `protocolClasses` is consulted
        // per request, so a session that already exists and has already been
        // used is gated from its next request onwards.
        case "start-later":
            let url = URL(string: "https://httpbin.org/get")!
            // Built AND already used before start(), which is the real case:
            // an app that has been running for a while with a live session.
            let existingSession = URLSession(configuration: .default)
            let warmup = await client.perform(existingSession, url: url)

            SimulatorNetwork.start()

            let existingAfterStart = await client.perform(existingSession, url: url)
            let freshAfterStart = await client.perform(URLSession(configuration: .default), url: url)
            emit([
                "scenario": "start-later",
                "existingSessionBeforeStart": outcomeLabel(warmup),
                "existingSessionAfterStart": outcomeLabel(existingAfterStart),
                "freshSessionAfterStart": outcomeLabel(freshAfterStart),
                "existingAfterStartError": errorLabel(existingAfterStart)
            ])

        // Both SimNap and the host app swizzle the same protocolClasses
        // getter. Each must chain through the other: SimNap gates its request,
        // and the app's own protocol still handles the one it claims.
        case "coexistence":
            HostAppProtocol.installSwizzle()
            SimulatorNetwork.start()
            let session = URLSession(configuration: .default)
            let hostAppOutcome = await client.perform(
                session,
                url: URL(string: "https://\(HostAppProtocol.markerHost)/ping")!
            )
            let gatedOutcome = await client.perform(session, url: URL(string: "https://httpbin.org/get")!)
            emit([
                "scenario": "coexistence",
                "hostAppProtocolStillRuns": HostAppProtocol.didHandleRequest,
                "hostAppRequest": outcomeLabel(hostAppOutcome),
                "simnapGatedRequest": outcomeLabel(gatedOutcome),
                "stateAtStart": describe(SimulatorNetwork.state)
            ])

        // The other installation order, which is the real one in Bringoz:
        // SimNap swizzles first, the app's own swizzle lands on top. stop()
        // must not take the app's interception down with it.
        case "coexistence-reversed":
            SimulatorNetwork.start()
            HostAppProtocol.installSwizzle()
            let markerURL = URL(string: "https://\(HostAppProtocol.markerHost)/ping")!

            let beforeStop = await client.perform(URLSession(configuration: .default), url: markerURL)
            let handledBeforeStop = HostAppProtocol.didHandleRequest

            HostAppProtocol.resetHandledFlag()
            SimulatorNetwork.stop()
            let afterStop = await client.perform(URLSession(configuration: .default), url: markerURL)

            emit([
                "scenario": "coexistence-reversed",
                "hostHandledBeforeStop": handledBeforeStop,
                "hostRequestBeforeStop": outcomeLabel(beforeStop),
                "hostHandledAfterStop": HostAppProtocol.didHandleRequest,
                "hostRequestAfterStop": outcomeLabel(afterStop)
            ])

        // Reported, not asserted: URLSession.shared is built internally and may
        // not go through the intercepted class methods at all.
        case "shared-session":
            SimulatorNetwork.start()
            let outcome = await client.perform(URLSession.shared, url: URL(string: "https://httpbin.org/get")!)
            emit(payload(scenario: "shared-session", outcome: outcome, extra: [
                "stateAtStart": describe(SimulatorNetwork.state)
            ]))

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
            // Start the request and give URL Loading System time to admit it
            // while online before asking the harness to transition offline.
            let requestTask = Task {
                await client.perform(client.integratedSession, url: URL(string: "https://httpbin.org/delay/6")!)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            print("SIMNAP_READY")
            let outcome = await requestTask.value
            emit(payload(scenario: "delayed-watch", outcome: outcome, extra: [:]))

        // Reachability mirrors the gate with nothing running: no monitor, no timer,
        // no request. Reported together with the gate it was derived from.
        case "reachability":
            emit([
                "scenario": "reachability",
                "state": describe(SimulatorNetwork.state),
                "isReachable": SimulatorNetwork.isReachable,
                "probeEnabled": SimulatorNetwork.isReachabilityProbeEnabled
            ])

        case "reachability-watch":
            let initial = SimulatorNetwork.isReachable
            print("SIMNAP_READY")
            for await value in SimulatorNetwork.reachability {
                guard value != initial else { continue }
                emit([
                    "scenario": "reachability-watch",
                    "initialIsReachable": initial,
                    "isReachable": value,
                    "state": describe(SimulatorNetwork.state)
                ])
                return
            }

        // Off by default means off. The endpoints are answering failure and the
        // gate is online: a probe that ran would drive this to false, and one that
        // never started leaves the gate's verdict alone and sends nothing.
        case "reachability-probe-off":
            ProbeEndpointProtocol.installSwizzle()
            ProbeEndpointProtocol.shouldSucceed = false
            let defaultEnabled = SimulatorNetwork.isReachabilityProbeEnabled
            let initiallyReachable = SimulatorNetwork.isReachable
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            emit([
                "scenario": "reachability-probe-off",
                "probeEnabledByDefault": defaultEnabled,
                "state": describe(SimulatorNetwork.state),
                "isReachableAtStart": initiallyReachable,
                "isReachable": SimulatorNetwork.isReachable,
                "probeRequests": ProbeEndpointProtocol.requestCount
            ])

        // On, the probe overrides the gate's "online" with what it measured - the
        // case it exists for, the machine unable to reach anything. Off again, the
        // verdict returns to the gate and the traffic stops.
        case "reachability-probe-toggle":
            ProbeEndpointProtocol.installSwizzle()
            ProbeEndpointProtocol.shouldSucceed = false
            let stateAtStart = describe(SimulatorNetwork.state)
            let beforeEnable = SimulatorNetwork.isReachable

            SimulatorNetwork.isReachabilityProbeEnabled = true
            let becameUnreachable = await waitForReachable(false, timeout: 20)
            let requestsWhileOn = ProbeEndpointProtocol.requestCount

            SimulatorNetwork.isReachabilityProbeEnabled = false
            let afterDisable = SimulatorNetwork.isReachable
            let requestsAtDisable = ProbeEndpointProtocol.requestCount
            try? await Task.sleep(nanoseconds: 5_000_000_000)

            emit([
                "scenario": "reachability-probe-toggle",
                "state": stateAtStart,
                "isReachableBeforeEnable": beforeEnable,
                "becameUnreachable": becameUnreachable,
                "requestsWhileOn": requestsWhileOn,
                "isReachableAfterDisable": afterDisable,
                "isReachable": SimulatorNetwork.isReachable,
                "requestsAfterDisable": ProbeEndpointProtocol.requestCount - requestsAtDisable
            ])

        // Closing the gate is not something that has to be measured. The verdict is
        // false the moment the gate moves, and the probe is torn down for the
        // duration - an app switched offline from the menu bar sends nothing at all.
        // The wait after the transition is longer than the probe's own interval, so
        // a probe still running would be caught by it.
        case "reachability-probe-gate-silence":
            ProbeEndpointProtocol.installSwizzle()
            ProbeEndpointProtocol.shouldSucceed = true
            SimulatorNetwork.isReachabilityProbeEnabled = true
            let probeWasRunning = await waitForProbeRequests(atLeast: 2, timeout: 20)
            print("SIMNAP_READY")

            let wentUnreachable = await waitForReachable(false, timeout: 20)
            let requestsAtTransition = ProbeEndpointProtocol.requestCount
            try? await Task.sleep(nanoseconds: 14_000_000_000)

            emit([
                "scenario": "reachability-probe-gate-silence",
                "probeWasRunning": probeWasRunning,
                "wentUnreachable": wentUnreachable,
                "state": describe(SimulatorNetwork.state),
                "isReachable": SimulatorNetwork.isReachable,
                "requestsWhileGateOffline": ProbeEndpointProtocol.requestCount - requestsAtTransition
            ])

        default:
            emit(["scenario": scenario, "outcome": "failure", "error": "unknown-scenario"])
        }
    }

    /// Polls rather than watching the stream on purpose: the scenarios that use it
    /// are asserting the verdict itself, and a stream bug would otherwise make them
    /// fail for the wrong reason. `reachability-watch` covers the stream.
    private static func waitForReachable(_ expected: Bool, timeout: TimeInterval) async -> Bool {
        await waitUntil(timeout: timeout) { SimulatorNetwork.isReachable == expected }
    }

    private static func waitForProbeRequests(atLeast count: Int, timeout: TimeInterval) async -> Bool {
        await waitUntil(timeout: timeout) { ProbeEndpointProtocol.requestCount >= count }
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    /// Guards the single resume across the connection handler and the timeout.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    private static func runNetworkFrameworkProbe() async {
        await withCheckedContinuation { continuation in
            let start = Date()
            let gate = ResumeOnce()
            let connection = NWConnection(host: "www.apple.com", port: 443, using: .tls)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    let elapsed = Date().timeIntervalSince(start)
                    emit(["scenario": "network-framework", "outcome": "success", "elapsedMs": Int(elapsed * 1000)])
                    connection.cancel()
                    continuation.resume()
                case .failed(let error):
                    guard gate.claim() else { return }
                    emit(["scenario": "network-framework", "outcome": "failure", "error": "\(error)"])
                    connection.cancel()
                    continuation.resume()
                default:
                    break
                }
            }
            connection.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                guard gate.claim() else { return }
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

    private static func outcomeLabel(_ outcome: RequestOutcome) -> String {
        outcome.isSuccess ? "success" : "failure"
    }

    private static func errorLabel(_ outcome: RequestOutcome) -> String {
        if case .failure(let code, _) = outcome { return code }
        return ""
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
