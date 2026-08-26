import Foundation

/// Intercepts new HTTP/HTTPS requests only while simulated offline.
/// Online requests are left entirely to the caller's URL loading system.
public final class SimulatorURLProtocol: URLProtocol, @unchecked Sendable {
    public override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return Runtime.shared.offlineErrorForInterception != nil
    }

    public override class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest ?? task.originalRequest else { return false }
        return canInit(with: request)
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        // Once URL Loading System assigns a request to this protocol it cannot
        // be handed back. If the state changed to online after canInit, keep the
        // decision made while it was offline and fail deterministically.
        let error = Runtime.shared.offlineErrorForClaimedRequest
        client?.urlProtocol(self, didFailWithError: URLError(error.urlErrorCode))
    }

    public override func stopLoading() {}
}
