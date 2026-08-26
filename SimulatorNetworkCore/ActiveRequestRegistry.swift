import Foundation

final class ActiveRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [ObjectIdentifier: SimulatorURLProtocol] = [:]

    func register(_ op: SimulatorURLProtocol) {
        lock.lock(); defer { lock.unlock() }
        operations[ObjectIdentifier(op)] = op
    }

    func unregister(_ op: SimulatorURLProtocol) {
        lock.lock(); defer { lock.unlock() }
        operations.removeValue(forKey: ObjectIdentifier(op))
    }

    /// Atomically takes and clears every currently registered operation, so no
    /// operation can be double-cancelled and no new one can slip in mid-snapshot.
    func snapshotAndClear() -> [SimulatorURLProtocol] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(operations.values)
        operations.removeAll()
        return all
    }
}
