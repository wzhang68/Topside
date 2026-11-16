import Foundation

/// Turns a fast stream of updates into batches delivered at most every
/// `interval`, keeping only the latest value per key.
///
/// The engine publishes one update per task change; with 30 agents each
/// emitting several events a second, redrawing the island per update would
/// waste the CPU the engine saves by batching its disk writes. The first
/// update after a quiet period is delivered at once, so single changes
/// (a task starting, finishing) still appear immediately.
public final class UpdateBatcher<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Key: Value] = [:]
    private var tasks: [Task<Void, Never>] = []

    public init() {}

    /// Start consuming `updates`. `deliver` is called with each batch, in order, never concurrently.
    public func start(_ updates: AsyncStream<Value>, key: @escaping @Sendable (Value) -> Key,
                      interval: Duration = .milliseconds(100),
                      deliver: @escaping @Sendable ([Key: Value]) async -> Void) {
        let (signal, signalled) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let consumer = Task { [self] in
            for await value in updates {
                lock.withLock { pending[key(value)] = value }
                signalled.yield()
            }
            signalled.finish()
        }
        let flusher = Task { [self] in
            for await _ in signal {
                let batch = lock.withLock { () -> [Key: Value] in
                    defer { pending.removeAll(keepingCapacity: true) }
                    return pending
                }
                if !batch.isEmpty { await deliver(batch) }
                try? await Task.sleep(for: interval)
            }
            // The stream ended: hand over anything that arrived during the last pause.
            let rest = lock.withLock { pending }
            if !rest.isEmpty { await deliver(rest) }
        }
        lock.withLock { tasks = [consumer, flusher] }
    }

    public func cancel() {
        for t in lock.withLock({ tasks }) { t.cancel() }
    }
}
