import Foundation
import SimulatorNetworkCore

/// Reads and writes the package-owned record inside one Simulator's global
/// defaults domain by running `defaults` through `simctl spawn`, which
/// resolves preference domains against that Simulator's own home directory.
enum PersistenceWriter {
    static func readRecord(udid: String) -> PersistedSimulatorNetworkState? {
        guard let output = try? SimulatorDiscovery.runSimctl([
            "spawn", udid, "defaults", "read", "NSGlobalDomain", SimulatorNetworkPersistenceKey.stateKey
        ]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PersistedSimulatorNetworkState.self, from: data)
    }

    static func writeRecord(udid: String, record: PersistedSimulatorNetworkState) throws {
        let data = try JSONEncoder().encode(record)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "PersistenceWriter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode record."])
        }
        try SimulatorDiscovery.runSimctl([
            "spawn", udid, "defaults", "write", "NSGlobalDomain", SimulatorNetworkPersistenceKey.stateKey, "-string", json
        ])
    }
}
