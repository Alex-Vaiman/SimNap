import Foundation

/// Where SimNap keeps its lock files.
///
/// Deliberately not `FileManager.temporaryDirectory`, which follows `TMPDIR`.
/// A shell-launched CLI and a Finder/launchd-launched app bundle are given
/// different values, and `flock` on two different paths excludes nothing — so
/// the per-Simulator writer lock would silently stop serializing the menu bar
/// app against the CLI. That is precisely the pairing that installing the app
/// as a normal application introduces.
public enum SimNapSupportDirectory {
    /// Resolves to `~/Library/Caches/com.simnap.simulator-network/locks`,
    /// which is the same path in every launch context.
    public static func locks() throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = caches
            .appendingPathComponent("com.simnap.simulator-network", isDirectory: true)
            .appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
