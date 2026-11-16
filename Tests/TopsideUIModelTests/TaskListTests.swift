import Foundation
import Testing
import TopsideCore
@testable import TopsideUIModel

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func task(_ title: String, _ status: TaskStatus, repo: String = "/src/app", age: Double = 0,
          started: Bool = true, paused: Bool = false) -> TopsideTask {
    var t = TopsideTask(prompt: title, repo: repo, agent: AgentKind("fake"), now: t0.addingTimeInterval(-age))
    t.status = status
    t.startedAt = started ? t.createdAt : nil
    t.paused = paused
    return t
}

@Suite struct TaskListTests {
    @Test func countsGroupRunningAndQueuedTogether() {
        let c = IslandCounts([
            task("a", .running), task("b", .queued), task("c", .queued, started: false),
            task("d", .needsYou), task("e", .failed), task("f", .ready), task("g", .ready), task("h", .closed),
        ])
        #expect(c == IslandCounts(active: 3, needsYou: 1, failed: 1, ready: 2))
        #expect(IslandCounts([task("x", .closed)]).isEmpty)
    }

    @Test func flatListIsByUrgencyThenNewestAndHidesClosed() {
        let list = TaskListLayout([
            task("old running", .running, age: 100), task("ready", .ready), task("closed", .closed),
            task("new running", .running, age: 1), task("needs you", .needsYou, age: 500), task("failed", .failed),
        ])
        guard case .flat(let tasks) = list else { Issue.record("expected a flat list"); return }
        #expect(tasks.map(\.title) == ["needs you", "failed", "ready", "new running", "old running"])
    }

    @Test func manyTasksAreGroupedByRepoWithTasksNeedingYouPinned() {
        var tasks = (0..<6).map { task("api \($0)", .running, repo: "/src/api", age: Double($0)) }
        tasks += (0..<3).map { task("web \($0)", .running, repo: "/src/web", age: Double($0)) }
        tasks.append(task("web ready", .ready, repo: "/src/web"))
        tasks.append(task("api needs you", .needsYou, repo: "/src/api"))
        guard case .grouped(let pinned, let groups) = TaskListLayout(tasks) else {
            Issue.record("expected groups"); return
        }
        #expect(pinned.map(\.title) == ["api needs you"])
        // web has the more urgent task (ready beats running), so it comes first.
        #expect(groups.map(\.name) == ["web", "api"])
        #expect(groups[0].tasks.first?.title == "web ready")
        #expect(groups[1].tasks.count == 6)
        #expect(TaskListLayout(tasks).allTasks.count == 11)
    }

    @Test func groupingStartsAboveTheThreshold() {
        let eight = (0..<8).map { task("t\($0)", .running, repo: "/r\($0 % 2)") }
        if case .grouped = TaskListLayout(eight) { Issue.record("8 tasks should stay flat") }
        if case .flat = TaskListLayout(eight + [task("t8", .running)]) { Issue.record("9 tasks should be grouped") }
    }

    @Test func repoNamesAreDisambiguated() {
        let names = RepoNames.displayNames(for: ["/a/work/app", "/a/home/app", "/a/api", "/a/api"])
        #expect(names == ["/a/work/app": "work/app", "/a/home/app": "home/app", "/a/api": "api"])
    }
}

@Suite struct TaskRowTests {
    @Test func symbolsAndDetails() {
        #expect(TaskRow(task("x", .queued, started: false), agentName: "A", repoName: "r").symbol == .waiting)
        #expect(TaskRow(task("x", .queued), agentName: "A", repoName: "r").detail == "正在准备工作区")
        #expect(TaskRow(task("x", .running, paused: true), agentName: "A", repoName: "r").symbol == .paused)

        var failed = task("x", .failed)
        failed.failure = Failure(kind: .agent, message: "The agent exited with code 1.")
        #expect(TaskRow(failed, agentName: "A", repoName: "r").detail == "The agent exited with code 1.")

        var ready = task("x", .ready)
        ready.result = TaskResult(files: [FileChange(path: "a", added: 40, deleted: 7),
                                          FileChange(path: "b", added: 2, deleted: 0),
                                          FileChange(path: "c.png", added: nil, deleted: nil)],
                                  summary: nil, costUSD: nil, permissionDenials: 0)
        #expect(TaskRow(ready, agentName: "A", repoName: "r").detail == "3 个文件 +42 −7")
    }

    @Test func runningRowShowsTheCurrentActivity() {
        var t = task("x", .running)
        t.currentStep = 0
        var run = RunRecord(number: 1, directory: "/d", launchedAt: t0)
        run.activity = "Bash npm test\n--watch=false"
        t.steps[0].runs = [run]
        let row = TaskRow(t, agentName: "A", repoName: "r")
        #expect(row.detail == "Bash npm test --watch=false")
        #expect(row.isLive)
        #expect(row.steps == nil)   // single-step recipes show no step chips
    }

    @Test func clockStopsWhenTheTaskSettles() {
        var t = task("x", .ready, age: 300)
        t.currentStep = 0
        var run = RunRecord(number: 1, directory: "/d", launchedAt: t0)
        run.endedAt = t0.addingTimeInterval(-48)
        t.steps[0].runs = [run]
        let row = TaskRow(t, agentName: "A", repoName: "r")
        #expect(!row.isLive)
        #expect(row.elapsed(now: t0.addingTimeInterval(1000)) == 252)
    }

    @Test func multiStepRecipesShowProgress() {
        let recipe = Recipe(name: "verify", steps: [
            .agent(AgentStep(role: "implement", access: .workspace, promptTemplate: "{{prompt}}")), .verify,
        ])
        var t = TopsideTask(prompt: "x", repo: "/r", agent: AgentKind("fake"), recipe: recipe, now: t0)
        t.status = .running
        t.steps[0].status = .succeeded
        t.steps[1].status = .running
        #expect(TaskRow(t, agentName: "A", repoName: "r").steps == "实现 ✓  验证 ◐")
    }

    @Test func durations() {
        #expect(UIText.duration(8) == "8 秒")
        #expect(UIText.duration(252) == "4 分 12 秒")
        #expect(UIText.duration(240) == "4 分")
        #expect(UIText.duration(3780) == "1 小时 3 分")
        #expect(UIText.shortDuration(59) == "59s")
        #expect(UIText.shortDuration(3780) == "1h3m")
    }
}
