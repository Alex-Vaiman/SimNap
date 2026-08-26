import Foundation

/// Host-side per-Simulator file lock. Guards the read-increment-write
/// critical section so two concurrent commands can never both observe
/// generation N and both write N + 1.
final class SimulatorLock {
    private let fileDescriptor: Int32

    init(udid: String) throws {
        let path = try SimNapSupportDirectory.locks()
            .appendingPathComponent("\(udid).lock").path

        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw NSError(
                domain: "SimulatorLock",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to open lock file at \(path)"]
            )
        }
        self.fileDescriptor = fd
    }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        try apply(operation: LOCK_EX, description: "acquire")
        do {
            let result = try operation()
            try apply(operation: LOCK_UN, description: "release")
            return result
        } catch {
            _ = flock(fileDescriptor, LOCK_UN)
            throw error
        }
    }

    private func apply(operation: Int32, description: String) throws {
        while flock(fileDescriptor, operation) != 0 {
            guard errno == EINTR else {
                throw NSError(
                    domain: "SimulatorLock",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to \(description) Simulator lock."]
                )
            }
        }
    }

    deinit { close(fileDescriptor) }
}
