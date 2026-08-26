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
    public let state: PersistedSimulatorNetworkState

    public init(device: SimulatorDevice, state: PersistedSimulatorNetworkState) {
        self.device = device
        self.state = state
    }
}

public protocol SimulatorNetworkHostControlling {
    func bootedDevices() throws -> [SimulatorDevice]
    func bootedDeviceStatuses() throws -> [SimulatorDeviceStatus]
    func status(for udid: String) throws -> PersistedSimulatorNetworkState
    func setOffline(deviceUDID: String, error: OfflineError) throws
    func setOnline(deviceUDID: String) throws
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
            SimulatorDeviceStatus(
                device: device,
                state: try PersistenceWriter.readRecord(udid: device.udid) ?? .initial
            )
        }
    }

    public func status(for udid: String) throws -> PersistedSimulatorNetworkState {
        try validateBooted(udid)
        return try PersistenceWriter.readRecord(udid: udid) ?? .initial
    }

    public func setOffline(deviceUDID: String, error: OfflineError) throws {
        try mutate(deviceUDID: deviceUDID) { previous in
            PersistedSimulatorNetworkState(generation: previous.generation + 1, mode: .offline, offlineError: error)
        }
    }

    public func setOnline(deviceUDID: String) throws {
        try mutate(deviceUDID: deviceUDID) { previous in
            PersistedSimulatorNetworkState(generation: previous.generation + 1, mode: .online, offlineError: previous.offlineError)
        }
    }

    private func mutate(deviceUDID: String, transform: (PersistedSimulatorNetworkState) -> PersistedSimulatorNetworkState) throws {
        try validateBooted(deviceUDID)

        let lock = try SimulatorLock(udid: deviceUDID)
        try lock.withLock {
            let previous = try PersistenceWriter.readRecord(udid: deviceUDID) ?? .initial
            let next = transform(previous)
            try PersistenceWriter.writeRecord(udid: deviceUDID, record: next)
        }

        do {
            try DarwinNotifier.notify(udid: deviceUDID)
        } catch {
            do {
                try DarwinNotifier.notify(udid: deviceUDID)
            } catch {
                throw HostCoreError.statePersistedButNotificationFailed(deviceUDID, String(describing: error))
            }
        }
    }

    private func validateBooted(_ udid: String) throws {
        guard try SimulatorDiscovery.bootedDevices().contains(where: { $0.udid == udid }) else {
            throw HostCoreError.deviceNotBooted(udid)
        }
    }
}
