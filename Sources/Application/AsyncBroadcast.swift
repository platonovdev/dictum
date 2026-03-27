import Foundation

public final class AsyncBroadcast<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    public init() {}

    public func stream(
        bufferingPolicy: AsyncStream<Value>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<Value> {
        let id = UUID()

        return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
            self.lock.lock()
            self.continuations[id] = continuation
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    public func yield(_ value: Value) {
        lock.lock()
        let continuations = continuations.values
        lock.unlock()

        continuations.forEach { $0.yield(value) }
    }

    public func finish() {
        lock.lock()
        let continuations = Array(continuations.values)
        self.continuations.removeAll()
        lock.unlock()

        continuations.forEach { $0.finish() }
    }
}
