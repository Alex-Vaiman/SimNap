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

    /// A failed read outranks the states derived from it: reporting "all
    /// online" while a status is unknown would be a confident lie.
    static func resolve(statuses: [SimulatorDeviceStatus], refreshError: String?) -> StatusIcon {
        if refreshError != nil || statuses.contains(where: { $0.state == nil }) {
            return .warning
        }
        if statuses.contains(where: { $0.state?.mode == .offline }) {
            return .offline
        }
        return .neutral
    }

    var symbolName: String {
        switch self {
        case .neutral: return "wifi"
        case .offline: return "wifi.slash"
        case .warning: return "wifi.exclamationmark"
        }
    }

    /// Also used as the tooltip: the glyph alone cannot say which Simulator.
    var label: String {
        switch self {
        case .neutral: return "SimNap: all booted Simulators online"
        case .offline: return "SimNap: at least one Simulator is simulated offline"
        case .warning: return "SimNap: Simulator status unavailable"
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
