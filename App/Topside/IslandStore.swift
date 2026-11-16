import Foundation
import Observation
import TopsideCore
import TopsideEngine
import TopsideUIModel

/// The tasks the island shows, kept in step with the engine.
@MainActor @Observable
final class IslandStore {
    private(set) var tasks: [TaskID: TopsideTask] = [:]
    @ObservationIgnored private let batcher = UpdateBatcher<TaskID, TopsideTask>()

    var counts: IslandCounts { IslandCounts(tasks.values) }
    var layout: TaskListLayout { TaskListLayout(Array(tasks.values)) }
    var repoNames: [String: String] { RepoNames.displayNames(for: tasks.values.map(\.repo)) }

    func attach(_ engine: TaskEngine) async {
        // Subscribe first, then read everything, so no change falls in between.
        let updates = await engine.updates()
        for t in await engine.allTasks() { tasks[t.id] = t }
        batcher.start(updates, key: { $0.id }) { [weak self] batch in
            await self?.apply(batch)
        }
    }

    private func apply(_ batch: [TaskID: TopsideTask]) {
        for (id, t) in batch {
            // An update older than the snapshot taken in attach() must not overwrite it.
            if let current = tasks[id], current.updatedAt > t.updatedAt { continue }
            tasks[id] = t
        }
    }
}
