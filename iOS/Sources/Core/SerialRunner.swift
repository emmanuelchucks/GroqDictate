import Foundation

/// Runs `work` for one key at a time. A request made while a run is going
/// queues one more run and waits for it, so no request is skipped; requests
/// made during the same run share that next run.
@MainActor
final class SerialRunner<Key: Hashable> {
    private let work: @MainActor (Key) async -> Void
    private var running: [Key: Task<Void, Never>] = [:]
    private var runAgain: Set<Key> = []

    init(work: @escaping @MainActor (Key) async -> Void) {
        self.work = work
    }

    func run(_ key: Key) async {
        if let task = running[key] {
            runAgain.insert(key)
            await task.value
            return
        }
        let task = Task { @MainActor in
            repeat {
                runAgain.remove(key)
                await work(key)
            } while runAgain.contains(key)
            running[key] = nil
        }
        running[key] = task
        await task.value
    }

    func isRunning(_ key: Key) -> Bool {
        running[key] != nil
    }
}
