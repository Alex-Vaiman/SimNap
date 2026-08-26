import Foundation

/// Owns simulated network state, transport gating, and reconciliation against
/// the persisted per-Simulator record. Not an actor: `URLProtocol` callbacks
/// are synchronous, so the hot path needs lock-protected state, not await.
final class Runtime: @unchecked Sendable {
    static let shared = Runtime()

    private let lock = NSLock()
    private var started = false
    private var enabled = false
    private var lastAppliedGeneration: UInt64 = 0
    private var currentState: SimulatorNetworkState = .online
    private var darwinObserverInstalled = false
    private var continuations: [UUID: AsyncStream<SimulatorNetworkState>.Continuation] = [:]

    private let registry = ActiveRequestRegistry()

    private init() {}

    var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    func start() {
        ensureStarted()
    }

    func ensureStarted() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        enabled = true
        lock.unlock()

        guard isSimulator else { return }

        reconcile()
        installDarwinObserverIfNeeded()
    }

    func stop() {
        lock.lock()
        enabled = false
        lock.unlock()

        removeDarwinObserverIfNeeded()

        lock.lock()
        currentState = .online
        lock.unlock()
        broadcast(.online)
    }

    var state: SimulatorNetworkState {
        ensureStarted()
        lock.lock(); defer { lock.unlock() }
        return currentState
    }

    var isOffline: Bool {
        if case .offline = state { return true }
        return false
    }

    /// True when new requests should be allowed to reach real transport.
    var isGateOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled, isSimulator else { return true }
        if case .offline = currentState { return false }
        return true
    }

    var offlineErrorForGate: OfflineError {
        lock.lock(); defer { lock.unlock() }
        if case .offline(let error) = currentState { return error }
        return .timedOut
    }

    func states() -> AsyncStream<SimulatorNetworkState> {
        ensureStarted()
        return AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let snapshot = currentState
            lock.unlock()

            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func register(_ op: SimulatorURLProtocol) { registry.register(op) }
    func unregister(_ op: SimulatorURLProtocol) { registry.unregister(op) }

    // MARK: - Darwin wake-up

    private func installDarwinObserverIfNeeded() {
        lock.lock()
        if darwinObserverInstalled { lock.unlock(); return }
        darwinObserverInstalled = true
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<Runtime>.fromOpaque(observer).takeUnretainedValue().reconcile()
            },
            SimulatorNetworkPersistenceKey.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func removeDarwinObserverIfNeeded() {
        lock.lock()
        guard darwinObserverInstalled else { lock.unlock(); return }
        darwinObserverInstalled = false
        lock.unlock()

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

    /// Persisted state is authoritative; a Darwin notification is only a wake-up.
    /// A missed, duplicated, or reordered notification is harmless because every
    /// call re-reads the record and only ever applies a newer-or-equal generation.
    private func reconcile() {
        lock.lock()
        let isEnabled = enabled
        lock.unlock()
        guard isEnabled else { return }

        guard let record = PersistenceStore.read() else { return }

        lock.lock()
        guard record.generation >= lastAppliedGeneration else {
            lock.unlock()
            return
        }
        lastAppliedGeneration = record.generation

        let newState: SimulatorNetworkState = record.mode == .offline
            ? .offline(record.offlineError)
            : .online
        let enteringOffline = newState != currentState && isOfflineState(newState)
        currentState = newState
        lock.unlock()

        // Gate is flipped above, before any in-flight operation is cancelled,
        // so nothing can slip past the transition into the online path.
        if enteringOffline {
            let snapshot = registry.snapshotAndClear()
            for operation in snapshot {
                operation.failDueToSimulatedOffline(record.offlineError)
            }
        }

        broadcast(newState)
    }

    private func isOfflineState(_ state: SimulatorNetworkState) -> Bool {
        if case .offline = state { return true }
        return false
    }

    private func broadcast(_ state: SimulatorNetworkState) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(state) }
    }
}
