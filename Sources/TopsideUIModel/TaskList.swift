import Foundation
import TopsideCore

/// The numbers on the collapsed island (design doc 6.2 ①).
public struct IslandCounts: Sendable, Equatable {
    /// Running or queued (preparing a workspace, waiting for a slot or for an in-place task).
    public var active: Int
    public var needsYou: Int
    public var failed: Int
    public var ready: Int

    public init(active: Int = 0, needsYou: Int = 0, failed: Int = 0, ready: Int = 0) {
        self.active = active
        self.needsYou = needsYou
        self.failed = failed
        self.ready = ready
    }

    public init(_ tasks: some Sequence<TopsideTask>) {
        self.init()
        for t in tasks {
            switch t.status {
            case .running, .queued: active += 1
            case .needsYou: needsYou += 1
            case .failed: failed += 1
            case .ready: ready += 1
            case .closed: break
            }
        }
    }

    public var isEmpty: Bool { self == IslandCounts() }
}

/// One repository's tasks in the grouped list.
public struct TaskGroup: Sendable, Equatable, Identifiable {
    /// The repository path.
    public var id: String
    public var name: String
    public var tasks: [TopsideTask]
    public var counts: IslandCounts { IslandCounts(tasks) }
}

/// How the expanded island lays out its list (design doc 6.2 ③).
public enum TaskListLayout: Sendable, Equatable {
    case flat([TopsideTask])
    /// Tasks waiting for you stay on top, outside the groups, so grouping never hides them.
    case grouped(pinned: [TopsideTask], groups: [TaskGroup])

    /// Above this many open tasks, the list is grouped by repository.
    public static let groupingThreshold = 8

    public init(_ tasks: [TopsideTask], groupingThreshold: Int = TaskListLayout.groupingThreshold) {
        let open = TaskOrdering.sorted(tasks.filter { $0.status != .closed })
        guard open.count > groupingThreshold else {
            self = .flat(open)
            return
        }
        let pinned = open.filter { $0.status == .needsYou }
        let rest = open.filter { $0.status != .needsYou }
        let names = RepoNames.displayNames(for: rest.map(\.repo))
        var order: [String] = []
        var byRepo: [String: [TopsideTask]] = [:]
        for t in rest {   // already sorted, so each group's first task is its most urgent
            if byRepo[t.repo] == nil { order.append(t.repo) }
            byRepo[t.repo, default: []].append(t)
        }
        let groups = order.map { TaskGroup(id: $0, name: names[$0] ?? $0, tasks: byRepo[$0] ?? []) }
            .sorted { a, b in
                let ua = a.tasks[0].status.urgency, ub = b.tasks[0].status.urgency
                return ua != ub ? ua < ub : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        self = .grouped(pinned: pinned, groups: groups)
    }

    public var isGrouped: Bool {
        if case .grouped = self { return true }
        return false
    }

    /// Every task, in display order.
    public var allTasks: [TopsideTask] {
        switch self {
        case .flat(let tasks): return tasks
        case .grouped(let pinned, let groups): return pinned + groups.flatMap(\.tasks)
        }
    }
}

public enum TaskOrdering {
    /// Most urgent first; within a status, newest first. Same order as the engine and `topside list`.
    public static func sorted(_ tasks: [TopsideTask]) -> [TopsideTask] {
        tasks.sorted { a, b in
            if a.status.urgency != b.status.urgency { return a.status.urgency < b.status.urgency }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id.uuidString < b.id.uuidString   // stable, so rows do not swap places
        }
    }
}

public enum RepoNames {
    /// Short names for repositories: the folder name, or "parent/folder" when
    /// two repositories share a folder name.
    public static func displayNames(for paths: some Sequence<String>) -> [String: String] {
        let unique = Set(paths)
        var byBase: [String: [String]] = [:]
        for p in unique { byBase[base(p), default: []].append(p) }
        var result: [String: String] = [:]
        for (name, members) in byBase {
            for p in members {
                if members.count == 1 {
                    result[p] = name
                } else {
                    let parent = (((p as NSString).deletingLastPathComponent) as NSString).lastPathComponent
                    result[p] = parent.isEmpty ? p : "\(parent)/\(name)"
                }
            }
        }
        return result
    }

    public static func base(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
