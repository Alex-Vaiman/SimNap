import Foundation

/// Reachability as the app experiences it, which under a simulated outage is not
/// what a reachability framework reports. See `Reachability`.
///
/// Like the rest of the package this is Simulator-only: on a device `isReachable`
/// is `true`, `reachability` yields once and finishes, and
/// `isReachabilityProbeEnabled` does nothing — so an app can read it
/// unconditionally and combine it with whatever it already trusts:
///
///     var isReachable: Bool { myRealReachability.isReachable && SimulatorNetwork.isReachable }
public extension SimulatorNetwork {

    /// The current verdict. Reading it starts observing the gate; nothing else.
    static var isReachable: Bool {
        Reachability.shared.isReachable
    }

    /// The current verdict, and every change to it. Duplicates are not published.
    static var reachability: AsyncStream<Bool> {
        Reachability.shared.values()
    }

    /// Whether to measure against a real endpoint while the gate is online.
    ///
    /// `false` by default, and off means off: no monitor, no timer, and not a
    /// single request — the verdict is then a pure mirror of the gate. Switch it
    /// on, at any point, for the one case the gate cannot see: the host Mac losing
    /// its own connectivity, which leaves the Simulator's network path reporting
    /// `satisfied` and every request failing. An app that already measures
    /// reachability its own way does not need a second opinion, which is why this
    /// is opt-in rather than opt-out.
    ///
    /// No effect on a device.
    static var isReachabilityProbeEnabled: Bool {
        get { Reachability.shared.isProbeEnabled }
        set { Reachability.shared.isProbeEnabled = newValue }
    }
}
