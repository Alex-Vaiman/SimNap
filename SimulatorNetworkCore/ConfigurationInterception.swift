import Foundation

/// Makes `SimulatorNetwork.start()` mean what its name says.
///
/// A `URLSession` reads `protocolClasses` off its configuration when the
/// session is constructed. Exchanging that getter therefore reaches every
/// configuration — however and whenever it was built — rather than only the
/// ones handed out by the `default`/`ephemeral` factories after `start()`.
///
/// Compiled only for the Simulator. The usual objection to patching Foundation
/// is the risk it carries into production, and there is none here: on a device
/// this work is `#if`'d out entirely.
///
/// This only ever *adds* coverage. `configuration(from:)` is untouched, and
/// the getter filters this protocol out before re-inserting it, so an
/// explicitly integrated configuration cannot end up with it twice.
enum ConfigurationInterception {
    private static let lock = NSLock()
    private static var isInstalled = false

    static func install() {
        #if targetEnvironment(simulator)
        lock.lock(); defer { lock.unlock() }
        guard !isInstalled, exchangeProtocolClassesGetter() else { return }
        URLProtocol.registerClass(SimulatorURLProtocol.self)
        isInstalled = true
        #endif
    }

    static func uninstall() {
        #if targetEnvironment(simulator)
        lock.lock(); defer { lock.unlock() }
        guard isInstalled else { return }
        URLProtocol.unregisterClass(SimulatorURLProtocol.self)
        // Exchanging a second time restores the previous implementation.
        _ = exchangeProtocolClassesGetter()
        isInstalled = false
        #endif
    }

    #if targetEnvironment(simulator)
    /// Returns false if either method is missing, in which case nothing is
    /// exchanged and behaviour falls back to explicit integration.
    private static func exchangeProtocolClassesGetter() -> Bool {
        // `URLSessionConfiguration.default` is not a `URLSessionConfiguration`
        // — it is a private subclass. The getter has to be taken from the real
        // class of an instance, or the exchange silently never takes effect.
        guard let configurationClass: AnyClass = object_getClass(URLSessionConfiguration.default) else {
            return false
        }
        guard
            let original = class_getInstanceMethod(
                configurationClass,
                #selector(getter: URLSessionConfiguration.protocolClasses)
            ),
            let replacement = class_getInstanceMethod(
                URLSessionConfiguration.self,
                #selector(URLSessionConfiguration.simnapProtocolClasses)
            )
        else { return false }
        method_exchangeImplementations(original, replacement)
        return true
    }
    #endif
}

#if targetEnvironment(simulator)
extension URLSessionConfiguration {
    /// After the exchange this name reaches the previous implementation — the
    /// original getter, or the host application's own swizzle of it if there
    /// is one. Calling through rather than replacing is what lets both stand:
    /// an app already injecting its own `URLProtocol` keeps it.
    @objc fileprivate func simnapProtocolClasses() -> [AnyClass]? {
        guard let existing = simnapProtocolClasses() else {
            return [SimulatorURLProtocol.self]
        }
        var classes = existing.filter { $0 != SimulatorURLProtocol.self }
        classes.insert(SimulatorURLProtocol.self, at: 0)
        return classes
    }
}
#endif
