import Foundation

/// Host-side per-Simulator file lock. Guards the read-increment-write
/// critical section so two concurrent commands can never both observe
/// generation N and both write N + 1.
final class SimulatorLock {
    private let fileDescriptor: Int32

    init(udid: String) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.simnap.simulator-network/locks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(udid).lock").path

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

    func lock() { flock(fileDescriptor, LOCK_EX) }
    func unlock() { flock(fileDescriptor, LOCK_UN) }

    deinit { close(fileDescriptor) }
}
