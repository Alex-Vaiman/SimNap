import Foundation
import SimulatorNetworkCore

/// Posts the wake-up notification inside the target Simulator's own Darwin
/// notification server, not the host's. Uses `simctl notify_post` rather
/// than `simctl spawn ... notifyutil -p`: spawning a host binary does not
/// reliably join the Simulator's notifyd bootstrap namespace (it silently
/// fails with NOTIFY_STATUS_SERVER_NOT_FOUND while still exiting 0), whereas
/// `notify_post` is CoreSimulator's own dedicated command for this.
enum DarwinNotifier {
    static func notify(udid: String) throws {
        try SimulatorDiscovery.runSimctl([
            "notify_post", udid, SimulatorNetworkPersistenceKey.darwinNotificationName
        ])
    }
}
