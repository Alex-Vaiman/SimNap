import Foundation

/// Stands in for an application's own `URLProtocol` that swizzles the same
/// `protocolClasses` getter SimNap does — the shape used in the Bringoz app,
/// which has run this way in production for two years.
///
/// It exists to prove the two coexist. If SimNap replaced that getter instead
/// of chaining through it, an app's own interception would silently stop
/// working the moment SimNap was integrated.
final class HostAppProtocol: URLProtocol, @unchecked Sendable {
    static let markerHost = "hostapp.example"
    private static let handledKey = "HostAppProtocolHandled"

    /// Set when this protocol handled a request, so a test can tell whether it
    /// is still in the chain.
    static private(set) var didHandleRequest = false

    static func resetHandledFlag() { didHandleRequest = false }

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        return request.url?.host?.contains(markerHost) == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.didHandleRequest = true
        // Answers locally; the host does not resolve.
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("handled-by-host-app".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The same technique the application uses: exchange the instance getter,
    /// taken from the real class of a configuration instance.
    static func installSwizzle() {
        URLProtocol.registerClass(HostAppProtocol.self)
        guard
            let configurationClass: AnyClass = object_getClass(URLSessionConfiguration.default),
            let original = class_getInstanceMethod(
                configurationClass,
                #selector(getter: URLSessionConfiguration.protocolClasses)
            ),
            let replacement = class_getInstanceMethod(
                URLSessionConfiguration.self,
                #selector(URLSessionConfiguration.hostAppProtocolClasses)
            )
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

extension URLSessionConfiguration {
    @objc fileprivate func hostAppProtocolClasses() -> [AnyClass]? {
        guard let existing = hostAppProtocolClasses() else { return [HostAppProtocol.self] }
        var classes = existing.filter { $0 != HostAppProtocol.self }
        classes.insert(HostAppProtocol.self, at: 0)
        return classes
    }
}
