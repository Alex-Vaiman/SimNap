import Foundation

/// Stands in for the two endpoints the reachability probe measures against, so a
/// test can decide what the probe finds and count what it actually sent.
///
/// Without this the probe can only be observed on a machine whose real uplink is
/// down, which is not something a suite can arrange. With it, "the Mac lost its
/// connectivity while the gate says online" is an ordinary, repeatable case.
///
/// Installed by exchanging the same `protocolClasses` getter an application would
/// — the probe builds its own ephemeral session per round, so nothing handed to
/// it from outside would reach those requests.
final class ProbeEndpointProtocol: URLProtocol, @unchecked Sendable {

    private static let lock = NSLock()
    private static var succeeds = true
    private static var handled = 0

    /// What the endpoints answer from now on. Rounds already in flight are not
    /// rewritten; the next one sees the new value.
    static var shouldSucceed: Bool {
        get { lock.lock(); defer { lock.unlock() }; return succeeds }
        set { lock.lock(); succeeds = newValue; lock.unlock() }
    }

    /// How many endpoint requests the probe has made. A round measures both
    /// endpoints in parallel, so it advances by two.
    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return handled
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return Reply.all.contains { $0.host == host }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.handled += 1
        let succeeds = Self.succeeds
        Self.lock.unlock()

        guard
            succeeds,
            let host = request.url?.host,
            let reply = Reply.all.first(where: { $0.host == host })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        // Answered exactly as the real endpoint does, status and body both: a probe
        // that stopped validating the body would otherwise still pass here.
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = reply.body {
            client?.urlProtocol(self, didLoad: Data(body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func installSwizzle() {
        URLProtocol.registerClass(ProbeEndpointProtocol.self)
        guard
            let configurationClass: AnyClass = object_getClass(URLSessionConfiguration.default),
            let original = class_getInstanceMethod(
                configurationClass,
                #selector(getter: URLSessionConfiguration.protocolClasses)
            ),
            let replacement = class_getInstanceMethod(
                URLSessionConfiguration.self,
                #selector(URLSessionConfiguration.probeEndpointProtocolClasses)
            )
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    private struct Reply {
        static let all = [
            Reply(host: "connectivitycheck.gstatic.com", statusCode: 204, body: nil),
            Reply(host: "captive.apple.com", statusCode: 200, body: "Success")
        ]

        let host: String
        let statusCode: Int
        let body: String?
    }
}

extension URLSessionConfiguration {
    @objc fileprivate func probeEndpointProtocolClasses() -> [AnyClass]? {
        guard let existing = probeEndpointProtocolClasses() else { return [ProbeEndpointProtocol.self] }
        var classes = existing.filter { $0 != ProbeEndpointProtocol.self }
        classes.insert(ProbeEndpointProtocol.self, at: 0)
        return classes
    }
}
