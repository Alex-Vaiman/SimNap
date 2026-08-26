import Foundation

public enum Mode: String, Codable, Sendable {
    case online
    case offline
}

public enum OfflineError: String, Codable, Sendable {
    case timedOut
    case notConnectedToInternet

    var urlErrorCode: URLError.Code {
        switch self {
        case .timedOut: return .timedOut
        case .notConnectedToInternet: return .notConnectedToInternet
        }
    }
}

public struct PersistedSimulatorNetworkState: Codable, Sendable, Equatable {
    public let generation: UInt64
    public let mode: Mode
    public let offlineError: OfflineError

    public init(generation: UInt64, mode: Mode, offlineError: OfflineError) {
        self.generation = generation
        self.mode = mode
        self.offlineError = offlineError
    }

    public static let initial = PersistedSimulatorNetworkState(generation: 0, mode: .online, offlineError: .timedOut)
}

public enum SimulatorNetworkState: Equatable, Sendable {
    case online
    case offline(OfflineError)
}

public enum SimulatorNetworkPersistenceKey {
    public static let stateKey = "com.simnap.simulator-network.state"
    public static let darwinNotificationName = "com.simnap.simulator-network.state-changed"
}
