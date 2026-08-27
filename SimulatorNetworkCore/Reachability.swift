import Foundation

/// Whether the app can reach the network, as the app itself experiences it.
///
/// Reachability frameworks cannot answer that under SimNap. The gate lives in the
/// URL Loading System and leaves the interface untouched, so `NWPathMonitor`
/// reports `satisfied` straight through a simulated outage and reachability-driven
/// UI never reacts. The verdict here starts from the gate instead: while it is
/// offline, nothing the app sends leaves the process.
///
/// Simulator-only, like the rest of the package. On a device this is a constant
/// `true` and nothing is installed — there is no gate to combine with there, and
/// re-exporting `NWPathMonitor` is not worth putting a live network observer into
/// a production build. Compose it with whatever the app already trusts on device:
///
///     var isReachable: Bool { myRealReachability.isReachable && SimulatorNetwork.isReachable }
///
/// Advisory, as reachability always is: `true` is not a promise that the next
/// request will succeed, so it belongs in front of a retry or a status view rather
/// than in front of the request itself.
final class Reachability: @unchecked Sendable {
    static let shared = Reachability()

    private let queue = DispatchQueue(label: "com.simnap.simulator-network.reachability")
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    private init() {}

    #if targetEnvironment(simulator)
    /// One failed round is not enough to call the Simulator unreachable: requests
    /// in flight while the Mac changes network fail on their own. This guards a
    /// measured state only — the first result is always taken as it is.
    private static let failuresBeforeUnreachable = 2

    private let probe = ReachabilityProbe()

    private var started = false
    private var currentValue = true
    private var gateIsOffline = false
    private var probeIsEnabled = false
    private var measured: Bool?
    private var consecutiveFailures = 0
    private var probeGeneration: UInt64 = 0
    private var gateObservation: Task<Void, Never>?

    var isReachable: Bool {
        ensureStarted()
        return queue.sync { currentValue }
    }

    /// Off by default, and off means nothing runs: no monitor, no timer, and not a
    /// single request. Switching it on measures immediately; switching it off
    /// tears the probe down and returns the verdict to the gate alone.
    var isProbeEnabled: Bool {
        get {
            ensureStarted()
            return queue.sync { probeIsEnabled }
        }
        set {
            ensureStarted()

            let changed: Bool = queue.sync {
                guard probeIsEnabled != newValue else { return false }
                probeIsEnabled = newValue
                measured = nil
                consecutiveFailures = 0
                return true
            }

            guard changed else { return }

            syncProbe()
            recompute()
        }
    }

    func values() -> AsyncStream<Bool> {
        ensureStarted()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }

            queue.sync {
                continuations[id] = continuation
                continuation.yield(currentValue)
            }
        }
    }

    /// Observing the gate is what this type is for, so it costs nothing to defer:
    /// the observation starts on the first read and never restarts.
    private func ensureStarted() {
        let shouldObserve: Bool = queue.sync {
            guard !started else { return false }
            started = true
            gateIsOffline = Runtime.shared.isOffline
            currentValue = !gateIsOffline
            return true
        }

        guard shouldObserve else { return }

        gateObservation = Task { [weak self] in
            for await state in Runtime.shared.states() {
                guard let self else { return }
                self.apply(gate: state)
            }
        }
    }

    private func apply(gate state: SimulatorNetworkState) {
        let changed: Bool = queue.sync {
            let isOffline = state != .online
            guard gateIsOffline != isOffline else { return false }
            gateIsOffline = isOffline
            // Whatever was measured was measured on the other side of this
            // transition, which makes it evidence about nothing.
            measured = nil
            consecutiveFailures = 0
            return true
        }

        guard changed else { return }

        syncProbe()
        recompute()
    }

    /// What the probe measured. Reaching an endpoint once is enough to publish
    /// reachable, while going unreachable takes `failuresBeforeUnreachable` rounds
    /// in a row — unless nothing has been measured yet, in which case the first
    /// result stands as it is rather than being weighed against an assumption.
    private func apply(probeReached reached: Bool) {
        queue.sync {
            consecutiveFailures = reached ? 0 : consecutiveFailures + 1

            measured = measured == nil
                ? reached
                : reached || consecutiveFailures < Self.failuresBeforeUnreachable
        }

        recompute()
    }

    /// The gate first: while it is offline the app cannot reach anything, whatever
    /// the network underneath is doing. The probe only ever refines the other case.
    private func recompute() {
        queue.sync {
            let newValue: Bool
            if gateIsOffline {
                newValue = false
            } else if probeIsEnabled {
                newValue = measured ?? true
            } else {
                newValue = true
            }

            guard currentValue != newValue else { return }
            currentValue = newValue

            for continuation in continuations.values {
                continuation.yield(newValue)
            }
        }
    }

    /// The gate is both the cheaper answer and the certain one: while it is offline
    /// nothing the app sends leaves the process, so there is nothing left to
    /// measure. The probe is torn down for the duration rather than left polling
    /// against a closed gate — an app switched offline from the menu bar pays for
    /// no traffic at all, and the verdict was already `false` the moment the gate
    /// moved.
    private func syncProbe() {
        let (shouldRun, generation): (Bool, UInt64) = queue.sync {
            probeGeneration += 1
            return (probeIsEnabled && !gateIsOffline, probeGeneration)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.probe.apply(running: shouldRun, generation: generation) { [weak self] reached in
                self?.apply(probeReached: reached)
            }
        }
    }
    #else
    var isReachable: Bool { true }

    var isProbeEnabled: Bool {
        get { false }
        set {}
    }

    func values() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            continuation.yield(true)
            continuation.finish()
        }
    }
    #endif
}
