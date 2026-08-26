import Foundation

public struct SimulatorDevice: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let runtime: String

    public init(udid: String, name: String, runtime: String) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
    }
}

enum SimulatorDiscoveryError: Error, CustomStringConvertible {
    case simctlFailed(String)
    case decodingFailed

    var description: String {
        switch self {
        case .simctlFailed(let message): return "simctl failed: \(message)"
        case .decodingFailed: return "Failed to decode simctl output."
        }
    }
}

enum SimulatorDiscovery {
    static func bootedDevices() throws -> [SimulatorDevice] {
        let output = try runSimctl(["list", "devices", "-j"])
        guard let data = output.data(using: .utf8) else { throw SimulatorDiscoveryError.decodingFailed }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devicesByRuntime = json["devices"] as? [String: [[String: Any]]]
        else {
            throw SimulatorDiscoveryError.decodingFailed
        }

        var result: [SimulatorDevice] = []
        for (runtime, devices) in devicesByRuntime {
            for device in devices {
                guard
                    device["state"] as? String == "Booted",
                    let udid = device["udid"] as? String,
                    let name = device["name"] as? String
                else { continue }
                result.append(SimulatorDevice(udid: udid, name: name, runtime: runtime))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    @discardableResult
    static func runSimctl(_ arguments: [String]) throws -> String {
        try run(executable: "/usr/bin/xcrun", arguments: ["simctl"] + arguments)
    }

    @discardableResult
    static func run(executable: String, arguments: [String]) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.simnap.simulator-network/process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        guard
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        else {
            throw SimulatorDiscoveryError.simctlFailed("Failed to create process output files.")
        }

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        try stdout.close()
        try stderr.close()

        let outData = try Data(contentsOf: stdoutURL)
        let errData = try Data(contentsOf: stderrURL)
        let outString = String(data: outData, encoding: .utf8) ?? ""
        let errString = String(data: errData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw SimulatorDiscoveryError.simctlFailed(errString.isEmpty ? outString : errString)
        }
        return outString
    }
}
