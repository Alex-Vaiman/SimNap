import AppKit
import SimulatorNetworkCore
import SimulatorNetworkHostCore

/// The status-bar glyph.
///
/// Three aggregate states that have to be distinguishable at a glance — that
/// is the entire value of a status-bar app. A text label reading "SimNap" and
/// "SimNap ⚠︎" satisfied neither half of that: wide enough to crowd the bar,
/// similar enough to miss.
enum StatusIcon: CaseIterable {
    /// No controlled Simulator is simulated offline.
    case neutral
    /// At least one controlled Simulator is simulated offline.
    case offline
    /// A status could not be read, so what is shown may be stale or wrong.
    case warning

    /// An unknown status outranks the states derived from it: reporting "all
    /// online" while a status is unknown would be a confident lie.
    ///
    /// `hasLoadedSnapshot` is the startup case and matters as much as a failed
    /// read. The first snapshot costs one `simctl` call per booted Simulator,
    /// so for a second or two after every launch nothing is known yet — and an
    /// indicator whose job is to catch the eye must not spend that window
    /// reassuring instead.
    static func resolve(
        statuses: [SimulatorDeviceStatus],
        refreshError: String?,
        hasLoadedSnapshot: Bool
    ) -> StatusIcon {
        guard hasLoadedSnapshot else { return .warning }
        if refreshError != nil || statuses.contains(where: { $0.state == nil }) {
            return .warning
        }
        if statuses.contains(where: { $0.state?.mode == .offline }) {
            return .offline
        }
        return .neutral
    }

    /// Deliberately not the `wifi` family. The system's own network indicator
    /// is a Wi-Fi glyph, and SimNap sitting beside it with the same shape read
    /// as a second system indicator rather than as this app. A tint cannot fix
    /// that — a template image is recoloured by the menu bar by definition —
    /// so the shape has to carry the distinction.
    ///
    /// `questionmark.circle` rather than an exclamation for the unknown state:
    /// it is also what shows for a second or two on every launch, and an alarm
    /// glyph flashing at each start would train you to ignore it.
    var symbolName: String {
        switch self {
        case .neutral: return "network"
        case .offline: return "network.slash"
        case .warning: return "questionmark.circle"
        }
    }

    /// Also used as the tooltip: the glyph alone cannot say which Simulator.
    var label: String {
        switch self {
        case .neutral: return "SimNap: all booted Simulators online"
        case .offline: return "SimNap: at least one Simulator is simulated offline"
        case .warning: return "SimNap: Simulator status unknown"
        }
    }

    /// Shown only if the symbol cannot be loaded. An empty status item is
    /// indistinguishable from the app having failed to launch.
    var fallbackTitle: String {
        switch self {
        case .neutral: return "SimNap"
        case .offline: return "SimNap ⚠︎"
        case .warning: return "SimNap ?"
        }
    }

    /// A template image, so the menu bar renders it in its own foreground
    /// colour and it stays legible in both light and dark appearances.
    var image: NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        image?.isTemplate = true
        return image
    }
}
