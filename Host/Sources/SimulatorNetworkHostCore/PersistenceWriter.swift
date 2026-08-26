import Foundation
import SimulatorNetworkCore

enum PersistenceWriterError: Error, CustomStringConvertible {
    case invalidGlobalDomain
    case invalidStoredValue
    case invalidRecord(String)

    var description: String {
        switch self {
        case .invalidGlobalDomain:
            return "Failed to decode the Simulator's global defaults domain."
        case .invalidStoredValue:
            return "The stored SimNap state is not a string."
        case .invalidRecord(let message):
            return "The stored SimNap state is invalid: \(message)"
        }
    }
}

/// Reads and writes the package-owned record inside one Simulator's global
/// defaults domain by running `defaults` through `simctl spawn`, which
/// resolves preference domains against that Simulator's own home directory.
enum PersistenceWriter {
    static func readRecord(udid: String) throws -> PersistedSimulatorNetworkState? {
        let output = try SimulatorDiscovery.runSimctl([
            "spawn", udid, "defaults", "export", "NSGlobalDomain", "-"
        ])
        guard
            let plistData = output.data(using: .utf8),
            let domain = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else {
            throw PersistenceWriterError.invalidGlobalDomain
        }
        guard let storedValue = domain[SimulatorNetworkPersistenceKey.stateKey] else {
            return nil
        }
        guard let raw = storedValue as? String, let data = raw.data(using: .utf8) else {
            throw PersistenceWriterError.invalidStoredValue
        }
        do {
            return try JSONDecoder().decode(PersistedSimulatorNetworkState.self, from: data)
        } catch {
            throw PersistenceWriterError.invalidRecord(error.localizedDescription)
        }
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
