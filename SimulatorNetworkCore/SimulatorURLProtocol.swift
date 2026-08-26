import Foundation

/// Proxies every integrated request: forwards to real transport while the
/// gate is open, fails deterministically while it is closed. Every instance
/// guards its own terminal delivery so exactly one outcome ever reaches the
/// client, no matter which of completion / cancellation / offline transition
/// gets there first.
public final class SimulatorURLProtocol: URLProtocol, @unchecked Sendable {
    private static let recursionKey = "com.simnap.simulator-network.recursion-guard"

    private var backingSession: URLSession?
    private var backingTask: URLSessionDataTask?

    private let terminalLock = NSLock()
    private var terminalDelivered = false

    public override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return URLProtocol.property(forKey: recursionKey, in: request) == nil
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        guard Runtime.shared.isGateOpen else {
            deliverOfflineFailure(Runtime.shared.offlineErrorForGate)
            return
        }

        Runtime.shared.register(self)

        guard let forwarded = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            deliverOfflineFailure(.timedOut)
            return
        }
        URLProtocol.setProperty(true, forKey: Self.recursionKey, in: forwarded)

        let session = URLSession(
            configuration: .default,
            delegate: ForwardingDelegate(owner: self),
            delegateQueue: nil
        )
        backingSession = session
        let task = session.dataTask(with: forwarded as URLRequest)
        backingTask = task
        task.resume()
    }

    public override func stopLoading() {
        Runtime.shared.unregister(self)
        backingTask?.cancel()
        backingTask = nil
        backingSession?.invalidateAndCancel()
        backingSession = nil
    }

    /// Called by `Runtime` when a simulated-offline transition lands while
    /// this operation is still in flight.
    func failDueToSimulatedOffline(_ error: OfflineError) {
        backingTask?.cancel()
        deliverOfflineFailure(error)
    }

    private func deliverOfflineFailure(_ error: OfflineError) {
        guard markTerminal() else { return }
        Runtime.shared.unregister(self)
        client?.urlProtocol(self, didFailWithError: URLError(error.urlErrorCode))
    }

    private func markTerminal() -> Bool {
        terminalLock.lock(); defer { terminalLock.unlock() }
        if terminalDelivered { return false }
        terminalDelivered = true
        return true
    }

    fileprivate func forward(response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        terminalLock.lock()
        let alreadyTerminal = terminalDelivered
        terminalLock.unlock()
        guard !alreadyTerminal else {
            completionHandler(.cancel)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        completionHandler(.allow)
    }

    fileprivate func forward(data: Data) {
        terminalLock.lock()
        let alreadyTerminal = terminalDelivered
        terminalLock.unlock()
        guard !alreadyTerminal else { return }
        client?.urlProtocol(self, didLoad: data)
    }

    fileprivate func forwardCompletion(error: Error?) {
        guard markTerminal() else { return }
        Runtime.shared.unregister(self)
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    fileprivate func forwardRedirect(response: HTTPURLResponse, newRequest: URLRequest, completion: @escaping (URLRequest?) -> Void) {
        client?.urlProtocol(self, wasRedirectedTo: newRequest, redirectResponse: response)
        completion(newRequest)
    }

    /// Resolved locally rather than bridged through `URLProtocolClient`: the
    /// challenge's sender is tied to the completion-handler-based backing
    /// session and is not a valid legacy `URLAuthenticationChallengeSender`,
    /// so forwarding it through the client crashes CFNetwork's bridge.
    fileprivate func forwardChallenge(_ challenge: URLAuthenticationChallenge, completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completion(.performDefaultHandling, nil)
    }
}

private final class ForwardingDelegate: NSObject, URLSessionDataDelegate {
    private weak var owner: SimulatorURLProtocol?

    init(owner: SimulatorURLProtocol) {
        self.owner = owner
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let owner else { completionHandler(.cancel); return }
        owner.forward(response: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.forward(data: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.forwardCompletion(error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let owner else { completionHandler(newRequest); return }
        owner.forwardRedirect(response: response, newRequest: newRequest, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let owner else { completionHandler(.performDefaultHandling, nil); return }
        owner.forwardChallenge(challenge, completion: completionHandler)
    }
}
