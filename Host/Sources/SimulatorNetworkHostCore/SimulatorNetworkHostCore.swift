import Foundation
import SimulatorNetworkCore

public enum HostCoreError: Error, CustomStringConvertible {
    case deviceNotBooted(String)

    public var description: String {
        switch self {
        case .deviceNotBooted(let udid):
            return "Simulator \(udid) is not booted or does not exist. Run `simulator-network devices` for booted UDIDs."
        }
    }
}

public protocol SimulatorNetworkHostControlling {
    func bootedDevices() throws -> [SimulatorDevice]
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

    public func status(for udid: String) throws -> PersistedSimulatorNetworkState {
        try validateBooted(udid)
        return PersistenceWriter.readRecord(udid: udid) ?? .initial
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
        lock.lock()
        let next: PersistedSimulatorNetworkState
        do {
            let previous = PersistenceWriter.readRecord(udid: deviceUDID) ?? .initial
            next = transform(previous)
            try PersistenceWriter.writeRecord(udid: deviceUDID, record: next)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        try DarwinNotifier.notify(udid: deviceUDID)
    }

    private func validateBooted(_ udid: String) throws {
        guard try SimulatorDiscovery.bootedDevices().contains(where: { $0.udid == udid }) else {
            throw HostCoreError.deviceNotBooted(udid)
        }
    }
}
