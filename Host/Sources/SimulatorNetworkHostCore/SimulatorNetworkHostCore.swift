import Foundation
import SimulatorNetworkCore

public enum HostCoreError: Error, CustomStringConvertible {
    case deviceNotBooted(String)
    case statePersistedButNotificationFailed(String, String)

    public var description: String {
        switch self {
        case .deviceNotBooted(let udid):
            return "Simulator \(udid) is not booted or does not exist. Run `simulator-network devices` for booted UDIDs."
        case .statePersistedButNotificationFailed(let udid, let reason):
            return "State was saved for Simulator \(udid), but running apps were not notified: \(reason)"
        }
    }
}

public struct SimulatorDeviceStatus: Sendable, Equatable {
    public let device: SimulatorDevice
    public let state: PersistedSimulatorNetworkState?
    public let errorDescription: String?

    public init(device: SimulatorDevice, state: PersistedSimulatorNetworkState?, errorDescription: String? = nil) {
        self.device = device
        self.state = state
        self.errorDescription = errorDescription
    }
}

/// What a mutation actually did, captured inside the writer lock.
///
/// Reporting a fresh `status` read after the lock is released would describe
/// whatever the record happens to hold by then, which under concurrent
/// commands may be another process's write rather than this one's.
public struct MutationOutcome: Sendable, Equatable {
    /// The record this command left in place: the one it wrote, or the
    /// unchanged record it found when the requested state already applied.
    public let record: PersistedSimulatorNetworkState
    /// False when the requested state was already applied and nothing was written.
    public let changed: Bool

    public init(record: PersistedSimulatorNetworkState, changed: Bool) {
        self.record = record
        self.changed = changed
    }
}

public protocol SimulatorNetworkHostControlling {
    func bootedDevices() throws -> [SimulatorDevice]
    func bootedDeviceStatuses() throws -> [SimulatorDeviceStatus]
    func status(for udid: String) throws -> PersistedSimulatorNetworkState
    @discardableResult func setOffline(deviceUDID: String, error: OfflineError) throws -> MutationOutcome
    @discardableResult func setOnline(deviceUDID: String) throws -> MutationOutcome
}

/// Single source of state-mutation logic. The CLI and menu bar app both call
/// through this type; neither assembles shell commands or global-defaults
/// key knowledge on its own.
public final class SimulatorNetworkHostCore: SimulatorNetworkHostControlling {
    public init() {}

    public func bootedDevices() throws -> [SimulatorDevice] {
        try SimulatorDiscovery.bootedDevices()
    }

    public func bootedDeviceStatuses() throws -> [SimulatorDeviceStatus] {
        try bootedDevices().map { device in
            do {
                return SimulatorDeviceStatus(
                    device: device,
                    state: try PersistenceWriter.readRecord(udid: device.udid) ?? .initial
                )
            } catch {
                return SimulatorDeviceStatus(
                    device: device,
                    state: nil,
                    errorDescription: String(describing: error)
                )
            }
        }
    }

    public func status(for udid: String) throws -> PersistedSimulatorNetworkState {
        try validateBooted(udid)
        return try PersistenceWriter.readRecord(udid: udid) ?? .initial
    }

    @discardableResult
    public func setOffline(deviceUDID: String, error: OfflineError) throws -> MutationOutcome {
        try mutate(deviceUDID: deviceUDID) { previous in
            guard previous.epoch == nil || previous.mode != .offline || previous.offlineError != error else {
                return previous
            }
            return PersistedSimulatorNetworkState(
                epoch: previous.epoch ?? UUID(),
                generation: previous.generation + 1,
                mode: .offline,
                offlineError: error
            )
        }
    }

    @discardableResult
    public func setOnline(deviceUDID: String) throws -> MutationOutcome {
        try mutate(deviceUDID: deviceUDID) { previous in
            guard previous.epoch == nil || previous.mode != .online else { return previous }
            return PersistedSimulatorNetworkState(
                epoch: previous.epoch ?? UUID(),
                generation: previous.generation + 1,
                mode: .online,
                offlineError: previous.offlineError
            )
        }
    }

    private func mutate(
        deviceUDID: String,
        transform: (PersistedSimulatorNetworkState) -> PersistedSimulatorNetworkState
    ) throws -> MutationOutcome {
        try validateBooted(deviceUDID)

        let lock = try SimulatorLock(udid: deviceUDID)
        let outcome = try lock.withLock { () -> MutationOutcome in
            let previous = try previousRecordForMutation(deviceUDID: deviceUDID)
            let next = transform(previous)
            guard next != previous else {
                return MutationOutcome(record: previous, changed: false)
            }
            try PersistenceWriter.writeRecord(udid: deviceUDID, record: next)
            return MutationOutcome(record: next, changed: true)
        }

        try notifyWithRetry(deviceUDID: deviceUDID)
        return outcome
    }

    private func previousRecordForMutation(deviceUDID: String) throws -> PersistedSimulatorNetworkState {
        do {
            return try PersistenceWriter.readRecord(udid: deviceUDID) ?? .initial
        } catch let error as PersistenceWriterError where error.canBeOverwrittenByMutation {
            return .initial
        }
    }

    private func notifyWithRetry(deviceUDID: String) throws {
        for attempt in 0..<2 {
            do {
                try DarwinNotifier.notify(udid: deviceUDID)
                return
            } catch {
                guard attempt == 1 else { continue }
                throw HostCoreError.statePersistedButNotificationFailed(
                    deviceUDID,
                    String(describing: error)
                )
            }
        }
    }

    private func validateBooted(_ udid: String) throws {
        guard try SimulatorDiscovery.bootedDevices().contains(where: { $0.udid == udid }) else {
            throw HostCoreError.deviceNotBooted(udid)
        }
    }
}
