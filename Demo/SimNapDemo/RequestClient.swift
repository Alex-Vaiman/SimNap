import Foundation
import SimulatorNetworkCore

enum RequestOutcome {
    case success(status: Int, bytes: Int, elapsed: TimeInterval)
    case failure(code: String, elapsed: TimeInterval)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Thin wrapper shared by the interactive UI and the headless E2E runner so
/// both exercise the exact same integration path.
struct RequestClient {
    /// Integrated via `SimulatorNetwork.configuration` — subject to the gate.
    let integratedSession = URLSession(configuration: SimulatorNetwork.configuration(from: .default))

    /// Deliberately NOT integrated — used to demonstrate the documented
    /// boundary: unintegrated sessions are unaffected by simulated offline.
    let plainSession = URLSession(configuration: .default)

    func perform(_ session: URLSession, url: URL) async -> RequestOutcome {
        await perform(session, request: URLRequest(url: url))
    }

    func perform(_ session: URLSession, request: URLRequest) async -> RequestOutcome {
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(start)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return .success(status: code, bytes: data.count, elapsed: elapsed)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            let code = (error as? URLError)?.code.description ?? error.localizedDescription
            return .failure(code: code, elapsed: elapsed)
        }
    }
}

extension URLError.Code {
    var description: String {
        switch self {
        case .timedOut: return "timedOut"
        case .notConnectedToInternet: return "notConnectedToInternet"
        case .cancelled: return "cancelled"
        default: return "code(\(rawValue))"
        }
    }
}
