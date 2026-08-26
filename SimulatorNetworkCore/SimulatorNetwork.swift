import Foundation

/// Public entry point. On a physical device every call is a documented
/// pass-through: no observers are installed, no state is read, and
/// `configuration(from:)` returns the caller's configuration untouched.
public enum SimulatorNetwork {
    public static func start() {
        Runtime.shared.start()
    }

    /// Returns the local runtime to pass-through mode. Does not mutate the
    /// persisted per-Simulator state owned by the CLI/menu bar: restarting
    /// the package reconciles against that truth again.
    public static func stop() {
        Runtime.shared.stop()
    }

    /// Returns a copy of `base` with the package's proxy protocol installed
    /// first, after synchronously starting the runtime and reconciling
    /// persisted state. Sufficient on its own for normal integration.
    public static func configuration(from base: URLSessionConfiguration = .default) -> URLSessionConfiguration {
        #if targetEnvironment(simulator)
        Runtime.shared.ensureStarted()
        guard let copy = base.copy() as? URLSessionConfiguration else { return base }
        var protocols = copy.protocolClasses ?? []
        if !protocols.contains(where: { $0 == SimulatorURLProtocol.self }) {
            protocols.insert(SimulatorURLProtocol.self, at: 0)
        }
        copy.protocolClasses = protocols
        return copy
        #else
        return base
        #endif
    }

    public static var state: SimulatorNetworkState {
        #if targetEnvironment(simulator)
        return Runtime.shared.state
        #else
        return .online
        #endif
    }

    public static var isOffline: Bool {
        #if targetEnvironment(simulator)
        return Runtime.shared.isOffline
        #else
        return false
        #endif
    }

    public static var states: AsyncStream<SimulatorNetworkState> {
        #if targetEnvironment(simulator)
        return Runtime.shared.states()
        #else
        return AsyncStream { continuation in
            continuation.yield(.online)
            continuation.finish()
        }
        #endif
    }
}
