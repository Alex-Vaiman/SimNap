import Foundation

/// Prevents a second copy of the menu bar app from adding a duplicate status
/// item. Two instances are not a correctness problem — mutations are still
/// serialized by the per-Simulator file lock, which works across processes —
/// but they are indistinguishable in the menu bar and silently double the
/// `simctl` polling load.
///
/// The lock is held for the lifetime of the process and released by the
/// kernel when it exits, so a crashed instance leaves nothing to clean up.
enum SingleInstanceGuard {
    /// Deliberately never closed: closing the descriptor would drop the lock.
    private nonisolated(unsafe) static var heldDescriptor: Int32 = -1

    static func acquire() -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.simnap.simulator-network", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("menubar.lock").path

        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        // If the lock file itself is unusable, let the app run. A developer
        // convenience should not be blocked by a temporary-directory problem.
        guard descriptor >= 0 else { return true }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        heldDescriptor = descriptor
        return true
    }
}
