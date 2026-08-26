import ArgumentParser
import Foundation
import SimulatorNetworkCore
import SimulatorNetworkHostCore

@main
struct SimulatorNetworkCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simulator-network",
        abstract: "Deterministic application-level network control for cooperating iOS Simulator apps.",
        subcommands: [Offline.self, Online.self, Status.self, Devices.self]
    )
}

enum CLIError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

enum CLIOutput {
    /// `changed` is reported only for mutations. It distinguishes a command
    /// that wrote this record from one that found the state already applied,
    /// which matters when several commands run concurrently.
    static func printStatus(
        device: String,
        status: PersistedSimulatorNetworkState,
        json: Bool,
        changed: Bool? = nil
    ) {
        if json {
            var payload: [String: Any] = [
                "device": device,
                "state": status.mode.rawValue,
                "error": status.offlineError.rawValue,
                "generation": status.generation
            ]
            if let changed { payload["changed"] = changed }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        } else {
            print("device:     \(device)")
            print("state:      \(status.mode.rawValue)")
            if status.mode == .offline {
                print("error:      \(status.offlineError.rawValue)")
            }
            print("generation: \(status.generation)")
        }
    }
}

struct Offline: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Simulate offline for a booted Simulator.")

    @Option(name: .customLong("device"), help: "Exact Simulator UDID.")
    var device: String

    @Option(name: .customLong("error"), help: "timedOut | notConnectedToInternet")
    var errorMode: String = "timedOut"

    @Flag(name: .customLong("json"), help: "Machine-readable JSON output.")
    var json: Bool = false

    func run() throws {
        guard let offlineError = OfflineError(rawValue: errorMode) else {
            throw CLIError.message("Unknown --error '\(errorMode)'. Use timedOut or notConnectedToInternet.")
        }
        let host = SimulatorNetworkHostCore()
        let outcome = try host.setOffline(deviceUDID: device, error: offlineError)
        CLIOutput.printStatus(device: device, status: outcome.record, json: json, changed: outcome.changed)
    }
}

struct Online: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Restore online behavior for a booted Simulator.")

    @Option(name: .customLong("device"), help: "Exact Simulator UDID.")
    var device: String

    @Flag(name: .customLong("json"))
    var json: Bool = false

    func run() throws {
        let host = SimulatorNetworkHostCore()
        let outcome = try host.setOnline(deviceUDID: device)
        CLIOutput.printStatus(device: device, status: outcome.record, json: json, changed: outcome.changed)
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read persisted simulated network state.")

    @Option(name: .customLong("device"), help: "Exact Simulator UDID.")
    var device: String

    @Flag(name: .customLong("json"))
    var json: Bool = false

    func run() throws {
        let host = SimulatorNetworkHostCore()
        CLIOutput.printStatus(device: device, status: try host.status(for: device), json: json)
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List booted Simulators.")

    @Flag(name: .customLong("json"))
    var json: Bool = false

    func run() throws {
        let devices = try SimulatorNetworkHostCore().bootedDevices()
        if json {
            let payload = devices.map { ["udid": $0.udid, "name": $0.name, "runtime": $0.runtime] }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
               let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        } else if devices.isEmpty {
            print("No booted Simulators.")
        } else {
            for device in devices {
                print("\(device.udid)  \(device.name)  [\(device.runtime)]")
            }
        }
    }
}
