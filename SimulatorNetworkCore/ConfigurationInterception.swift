import Foundation

/// Makes `SimulatorNetwork.start()` mean what its name says.
///
/// A `URLSession` built from a `URLSessionConfiguration` consults only that
/// configuration's `protocolClasses`; `URLProtocol.registerClass` does not
/// reach it. So the only way for `start()` alone to gate an app's traffic is
/// to hand out configurations that already carry the protocol — which is what
/// this does, by exchanging the implementations of
/// `+[NSURLSessionConfiguration defaultSessionConfiguration]` and
/// `ephemeralSessionConfiguration`.
///
/// Compiled only for the Simulator. The usual objection to patching Foundation
/// is the risk it carries into production, and there is no production here:
/// on a device this file's work is `#if`'d out entirely.
///
/// This only ever *adds* coverage. `configuration(from:)` is untouched and
/// keeps working exactly as before, and a configuration obtained before
/// `start()` is unaffected — the same as today.
enum ConfigurationInterception {
    private static let lock = NSLock()
    private static var isInstalled = false

    static func install() {
        #if targetEnvironment(simulator)
        lock.lock(); defer { lock.unlock() }
        guard !isInstalled else { return }
        isInstalled = exchangeBothImplementations()
        #endif
    }

    static func uninstall() {
        #if targetEnvironment(simulator)
        lock.lock(); defer { lock.unlock() }
        guard isInstalled else { return }
        // Exchanging a second time restores the originals.
        _ = exchangeBothImplementations()
        isInstalled = false
        #endif
    }

    #if targetEnvironment(simulator)
    /// Returns false if either selector could not be found, in which case
    /// nothing is exchanged and behaviour falls back to explicit integration.
    private static func exchangeBothImplementations() -> Bool {
        let exchangedDefault = exchange(
            original: Selector(("defaultSessionConfiguration")),
            replacement: #selector(URLSessionConfiguration.simnapInterceptedDefault)
        )
        let exchangedEphemeral = exchange(
            original: Selector(("ephemeralSessionConfiguration")),
            replacement: #selector(URLSessionConfiguration.simnapInterceptedEphemeral)
        )
        return exchangedDefault || exchangedEphemeral
    }

    private static func exchange(original: Selector, replacement: Selector) -> Bool {
        guard
            let originalMethod = class_getClassMethod(URLSessionConfiguration.self, original),
            let replacementMethod = class_getClassMethod(URLSessionConfiguration.self, replacement)
        else { return false }
        method_exchangeImplementations(originalMethod, replacementMethod)
        return true
    }
    #endif
}

#if targetEnvironment(simulator)
extension URLSessionConfiguration {
    // After the exchange these names reach the original implementations, so
    // the recursive-looking call is the real `defaultSessionConfiguration`.
    @objc fileprivate class func simnapInterceptedDefault() -> URLSessionConfiguration {
        SimulatorNetwork.configuration(from: simnapInterceptedDefault())
    }

    @objc fileprivate class func simnapInterceptedEphemeral() -> URLSessionConfiguration {
        SimulatorNetwork.configuration(from: simnapInterceptedEphemeral())
    }
}
#endif
