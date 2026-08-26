import Foundation

/// Owns simulated network state and reconciliation against the persisted
/// per-Simulator record. A serial queue keeps lifecycle, notifications, state,
/// and stream delivery in one ordering domain while still allowing synchronous
/// reads from `URLProtocol.canInit`.
final class Runtime: @unchecked Sendable {
    static let shared = Runtime()

    private let queue = DispatchQueue(label: "com.simnap.simulator-network.runtime")
    private var started = false
    private var enabled = false
    private var lastAppliedEpoch: UUID?
    private var lastAppliedGeneration: UInt64 = 0
    private var currentState: SimulatorNetworkState = .online
    private var configuredOfflineError: OfflineError = .timedOut
    private var darwinObserverInstalled = false
    private var continuations: [UUID: AsyncStream<SimulatorNetworkState>.Continuation] = [:]

    private init() {}

    var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    func start() {
        queue.sync {
            started = true
            guard !enabled else { return }
            enabled = true

            guard isSimulator else { return }
            installDarwinObserverOnQueue()
            reconcileOnQueue()
        }

        // Outside the queue: the interception handed out below calls back into
        // `configuration(from:)`, which needs this queue. Only the explicit
        // `start()` installs it — `configuration(from:)` auto-starting the
        // runtime must not silently switch the whole process over.
        ConfigurationInterception.install()
    }

    func ensureStarted() {
        queue.sync {
            guard !started else { return }
            started = true
            enabled = true

            guard isSimulator else { return }

            // Observe first, then read. An update racing with startup is either
            // included in this read or queued for reconciliation afterward.
            installDarwinObserverOnQueue()
            reconcileOnQueue()
        }
    }

    func stop() {
        // Before the state teardown, so no further gated configurations are
        // handed out while stopping.
        ConfigurationInterception.uninstall()

        queue.sync {
            guard started else { return }

            enabled = false
            removeDarwinObserverOnQueue()

            guard currentState != .online else { return }
            currentState = .online
            broadcastOnQueue(.online)
        }
    }

    var state: SimulatorNetworkState {
        ensureStarted()
        return queue.sync { currentState }
    }

    var isOffline: Bool {
        if case .offline = state { return true }
        return false
    }

    var offlineErrorForInterception: OfflineError? {
        ensureStarted()
        return queue.sync {
            guard enabled, isSimulator, case .offline(let error) = currentState else {
                return nil
            }
            return error
        }
    }

    var offlineErrorForClaimedRequest: OfflineError {
        ensureStarted()
        return queue.sync { configuredOfflineError }
    }

    func states() -> AsyncStream<SimulatorNetworkState> {
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
                continuation.yield(currentState)
            }
        }
    }

    // MARK: - Darwin wake-up

    private func installDarwinObserverOnQueue() {
        guard !darwinObserverInstalled else { return }
        darwinObserverInstalled = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<Runtime>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                    .scheduleReconciliation()
            },
            SimulatorNetworkPersistenceKey.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func removeDarwinObserverOnQueue() {
        guard darwinObserverInstalled else { return }
        darwinObserverInstalled = false

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observer,
            CFNotificationName(SimulatorNetworkPersistenceKey.darwinNotificationName as CFString),
            nil
        )
    }

    // MARK: - Reconciliation

    private func scheduleReconciliation() {
        queue.async { [weak self] in
            self?.reconcileOnQueue()
        }
    }

    /// Persisted state is authoritative; a Darwin notification is only a wake-up.
    /// A missed, duplicated, or reordered notification is harmless because every
    /// call re-reads the record and only ever applies a newer-or-equal generation.
    private func reconcileOnQueue() {
        guard enabled else { return }
        guard let record = PersistenceStore.read() else { return }
        if record.epoch != lastAppliedEpoch {
            lastAppliedEpoch = record.epoch
            lastAppliedGeneration = 0
        }
        guard record.generation >= lastAppliedGeneration else { return }

        let newState: SimulatorNetworkState = record.mode == .offline
            ? .offline(record.offlineError)
            : .online

        lastAppliedGeneration = record.generation
        configuredOfflineError = record.offlineError
        guard newState != currentState else { return }
        currentState = newState
        broadcastOnQueue(newState)
    }

    private func broadcastOnQueue(_ state: SimulatorNetworkState) {
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }
}
