#if targetEnvironment(simulator)
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Measures what `NWPathMonitor` cannot on the Simulator: whether a request can
/// actually leave the machine. The path monitor still takes part, as one of the
/// triggers that ask for a fresh measurement.
///
/// Never running unless it was switched on. `Reachability` owns that decision and
/// nothing here starts on its own, so a consumer that leaves the probe off pays
/// for no monitor, no timer, and no request.
actor ReachabilityProbe {

    /// While unreachable the probe repeats quickly so recovery is picked up right
    /// away. While reachable it keeps repeating — slower — because the failure it
    /// exists for, the Mac losing its uplink, produces no path update at all.
    private static let intervalWhenUnreachable: UInt64 = 2_000_000_000
    private static let intervalWhenReachable: UInt64 = 10_000_000_000

    /// The endpoints answer in well under a second when the network is up, so a
    /// longer timeout only adds to the time it takes to notice a failure.
    private static let requestTimeout: TimeInterval = 2

    /// A session that has seen the path go `unsatisfied` keeps failing from its
    /// cached path and DNS state long after connectivity is back, which is exactly
    /// how a recovery goes unnoticed. Every round therefore runs on a session of
    /// its own and throws it away, so nothing cached survives between rounds.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        // A probe has to fail while offline, not wait for connectivity to return.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "com.simnap.simulator-network.probe.path")

    private var isReachable = true
    private var onChange: ((Bool) -> Void)?
    private var rounds: Task<Void, Never>?
    private var tick: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var lastCommand: UInt64 = 0

    /// Rounds run one at a time off this stream, so a burst of triggers — a path
    /// update, the app coming back to the front, the periodic tick — collapses
    /// into a single measurement instead of piling up.
    private var trigger: AsyncStream<Void>.Continuation?

    /// Commands carry a generation because they are delivered from unordered
    /// tasks: two gate transitions in quick succession must not leave a stale
    /// `start` landing after the `stop` that superseded it.
    func apply(running: Bool, generation: UInt64, onChange: @escaping (Bool) -> Void) {
        guard generation > lastCommand else { return }
        lastCommand = generation

        if running {
            start(onChange: onChange)
        } else {
            stop()
        }
    }

    private func start(onChange: @escaping (Bool) -> Void) {
        guard rounds == nil else { return }
        self.onChange = onChange

        var continuation: AsyncStream<Void>.Continuation?
        let triggers = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        trigger = continuation

        rounds = Task { [weak self] in
            for await _ in triggers {
                guard let self else { return }
                await self.measure()
                await self.scheduleTick()
            }
        }

        observeTriggers()
        requestProbe()
    }

    /// Leaves nothing running: no monitor, no timer, no round in flight. Turning
    /// the probe back on afterwards starts from a clean slate.
    private func stop() {
        trigger?.finish()
        trigger = nil
        rounds?.cancel()
        rounds = nil
        tick?.cancel()
        tick = nil
        onChange = nil
        isReachable = true

        monitor?.cancel()
        monitor = nil

        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
    }

    nonisolated func requestProbe() {
        Task { await trigger?.yield() }
    }

    /// Armed only once a round has answered, so the wait is measured from the
    /// result rather than from the request: a round that just failed is not left
    /// waiting out the reachable interval, and a slow round pushes the next one
    /// out instead of letting requests stack up.
    private func scheduleTick() {
        tick?.cancel()

        let interval = isReachable ? Self.intervalWhenReachable : Self.intervalWhenUnreachable
        tick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: interval)

            guard !Task.isCancelled else { return }

            self?.requestProbe()
        }
    }

    private func observeTriggers() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.requestProbe()
        }
        monitor.start(queue: monitorQueue)
        self.monitor = monitor

        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.requestProbe()
        }
        #endif
    }

    private func measure() async {
        let reached = await canReachAnyEndpoint()

        // A cancelled round says nothing about reachability.
        guard !Task.isCancelled else { return }

        isReachable = reached
        onChange?(reached)
    }

    /// The endpoints answer in parallel and the first valid reply wins, so one of
    /// them being blocked or slow on a given network cannot report a false
    /// unreachable.
    private nonisolated func canReachAnyEndpoint() async -> Bool {
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }

        return await withTaskGroup(of: Bool.self) { group in
            for endpoint in ReachabilityEndpoint.all {
                group.addTask { await Self.canReach(endpoint, using: session) }
            }

            for await reached in group where reached {
                group.cancelAll()
                return true
            }

            return false
        }
    }

    private static func canReach(
        _ endpoint: ReachabilityEndpoint,
        using session: URLSession
    ) async -> Bool {
        guard let url = URL(string: endpoint.url) else {
            return false
        }

        do {
            let (data, response) = try await session.data(from: url)

            guard (response as? HTTPURLResponse)?.statusCode == endpoint.statusCode else {
                return false
            }

            guard let reply = endpoint.reply else {
                return true
            }

            return String(decoding: data, as: UTF8.self).contains(reply)
        } catch {
            return false
        }
    }
}

/// The endpoints the operating systems probe themselves to tell real connectivity
/// from a captive portal. Both answer over HTTPS — so no ATS exception — with a
/// payload small and fixed enough to validate exactly, which is what separates a
/// genuine reply from a portal's login page. Two providers, so one of them being
/// blocked on a given network is not enough to report the app unreachable.
private struct ReachabilityEndpoint {

    static let all = [
        ReachabilityEndpoint(url: "https://connectivitycheck.gstatic.com/generate_204", statusCode: 204),
        ReachabilityEndpoint(url: "https://captive.apple.com/hotspot-detect.html", statusCode: 200, reply: "Success")
    ]

    let url: String
    let statusCode: Int

    /// Text the body has to contain, where the status code alone is not proof.
    var reply: String?
}
#endif
