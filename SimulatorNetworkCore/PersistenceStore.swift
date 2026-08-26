import Foundation

enum PersistenceStore {
    static func read() -> PersistedSimulatorNetworkState? {
        guard let raw = UserDefaults.standard.string(forKey: SimulatorNetworkPersistenceKey.stateKey) else {
            return nil
        }
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PersistedSimulatorNetworkState.self, from: data)
    }
}
