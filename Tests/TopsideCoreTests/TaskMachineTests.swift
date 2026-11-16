import Foundation
import Testing
@testable import TopsideCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let ws = WorkspaceInfo(path: "/w/task", branch: "topside/task", baseCommit: "abc123")

private func newTask(steps: Int = 1) -> TopsideTask {
    let recipe = Recipe(name: "test", steps: (0..<steps).map { i in
        .agent(AgentStep(role: "step\(i)", access: .workspace, promptTemplate: "{{prompt}}"))
    })
    return TopsideTask(prompt: "Add rate limiting\nmore detail", repo: "/r", agent: AgentKind("fake"),
                       recipe: recipe, now: t0)
}

/// Apply events in order, collecting every effect.
private func run(_ task: TopsideTask, _ events: [TaskEvent]) -> (TopsideTask, [TaskEffect]) {
    var t = task
    var all: [TaskEffect] = []
    for (i, e) in events.enumerated() {
        let (next, effects) = reduce(t, e, now: t0.addingTimeInterval(Double(i + 1)))
        t = next
        all += effects
    }
    return (t, all)
}

private func launched(_ step: Int, run n: Int = 1) -> TaskEvent {
    .runLaunched(step: step, RunRecord(number: n, directory: "/runs/\(step)-\(n)", launchedAt: t0))
}

@Suite struct TaskMachineTests {
    @Test func titleIsFirstLineAndTruncated() {
        #expect(newTask().title == "Add rate limiting")
        let long = TopsideTask.makeTitle(from: String(repeating: "x", count: 100), limit: 10)
        #expect(long == "xxxxxxxxx…")
        #expect(TopsideTask.makeTitle(from: "   ") == "Untitled task")
    }

    @Test func happyPathSingleStep() {
        let (t, effects) = run(newTask(), [
            .begin,
            .workspaceReady(ws),
            launched(0),
            .runEvents(step: 0, run: 1, events: [
                .sessionStarted(id: "s1", model: "m"),
                .toolStarted(id: "1", name: "Edit", detail: "src/a.ts"),
                .turnFinished(TurnSummary(isError: false, text: "Done.", costUSD: 0.02)),
            ], offset: 300),
            .runExited(step: 0, run: 1, exitCode: 0, detail: nil),
            .resultComputed(TaskResult(files: [FileChange(path: "src/a.ts", added: 3, deleted: 1)],
                                       summary: "Done.", costUSD: 0.02, permissionDenials: 0)),
        ])
        #expect(effects == [.prepareWorkspace, .launch(step: 0), .computeResult])
        #expect(t.status == .ready)
        #expect(t.workspace == ws)
        #expect(t.steps[0].status == .succeeded)
        let r = t.steps[0].runs[0]
        #expect(r.sessionID == "s1")
        #expect(r.summary == "Done.")
        #expect(r.costUSD == 0.02)
        #expect(r.activity == nil)
        #expect(r.exitCode == 0)
        #expect(t.result?.linesAdded == 3)
    }

    @Test func multiStepLaunchesNextThenComputesResult() {
        let (t, effects) = run(newTask(steps: 2), [
            .begin, .workspaceReady(ws), launched(0),
            .runExited(step: 0, run: 1, exitCode: 0, detail: nil),
            launched(1),
            .runExited(step: 1, run: 1, exitCode: 0, detail: nil),
        ])
        #expect(effects == [.prepareWorkspace, .launch(step: 0), .launch(step: 1), .computeResult])
        #expect(t.currentStep == 1)
        #expect(t.status == .running)   // until the result is computed
    }

    @Test func duplicateAndStaleEventsAreIgnored() {
        let events: [RunEvent] = [.permissionDenied(tool: "Bash", reason: nil)]
        let (t, effects) = run(newTask(), [
            .begin, .begin,                                 // duplicate begin
            .workspaceReady(ws), .workspaceReady(ws),       // duplicate ready
            launched(0),
            .runEvents(step: 0, run: 1, events: events, offset: 100),
            .runEvents(step: 0, run: 1, events: events, offset: 100),   // replayed batch
            .runEvents(step: 0, run: 9, events: events, offset: 500),   // unknown run
            .runExited(step: 0, run: 1, exitCode: 0, detail: nil),
            .runExited(step: 0, run: 1, exitCode: 1, detail: nil),      // second exit report
        ])
        #expect(effects == [.prepareWorkspace, .launch(step: 0), .computeResult])
        #expect(t.steps[0].runs[0].permissionDenials == 1)
        #expect(t.steps[0].runs[0].exitCode == 0)
    }

    @Test func multipleTurnsInOneRunUseTheLastResult() {
        // Claude Code with a background subagent emits two results in one run (M0 fixture "subagent").
        let (t, _) = run(newTask(), [
            .begin, .workspaceReady(ws), launched(0),
            .runEvents(step: 0, run: 1, events: [
                .subagentStarted(id: "a1", kind: "Explore", description: "List files"),
                .turnFinished(TurnSummary(isError: false, text: "Subagent still running.", costUSD: 0.003)),
            ], offset: 10),
            .runEvents(step: 0, run: 1, events: [
                .subagentFinished(id: "a1", status: "completed"),
                .turnFinished(TurnSummary(isError: false, text: "README.md", costUSD: 0.0067)),
            ], offset: 20),
            .runExited(step: 0, run: 1, exitCode: 0, detail: nil),
        ])
        let r = t.steps[0].runs[0]
        #expect(r.turnCount == 2)
        #expect(r.summary == "README.md")
        #expect(r.costUSD == 0.0067)
        #expect(r.activeSubagents.isEmpty)
    }

    @Test func userStopIsAttributedEvenWithExitCodeZero() {
        // In M0 fixture "sigint" Claude Code had already emitted a success result and exited 0.
        let (t, effects) = run(newTask(), [
            .begin, .workspaceReady(ws), launched(0),
            .interruptRequested(.user),
            .runExited(step: 0, run: 1, exitCode: 0, detail: nil),
        ])
        #expect(effects == [.prepareWorkspace, .launch(step: 0)])
        #expect(t.status == .failed)
        #expect(t.failure?.kind == .stopped)
    }

    @Test func stopBeforeStartAndDuringPreparation() {
        let (a, ea) = run(newTask(), [.interruptRequested(.user), .begin])
        #expect(a.status == .failed && a.failure?.kind == .stopped)
        #expect(ea.isEmpty)

        let (b, eb) = run(newTask(), [.begin, .interruptRequested(.user), .workspaceReady(ws)])
        #expect(b.status == .failed && b.failure?.kind == .stopped)
        #expect(eb == [.prepareWorkspace])
        #expect(b.workspace == ws)   // kept, so discard can clean it up
    }

    @Test func lostProcessAndAgentErrors() {
        let (lost, _) = run(newTask(), [
            .begin, .workspaceReady(ws), launched(0),
            .runExited(step: 0, run: 1, exitCode: nil, detail: "tail"),
        ])
        #expect(lost.failure == Failure(kind: .lost, message: "The agent process ended without reporting an exit code.",
                                        detail: "tail"))

        // M0 fixture "budget": error result, exit code 1.
        let (budget, _) = run(newTask(), [
            .begin, .workspaceReady(ws), launched(0),
            .runEvents(step: 0, run: 1, events: [.turnFinished(TurnSummary(
                isError: true, kind: "error_max_budget_usd", errors: ["Reached maximum budget ($0.0005)"]))], offset: 5),
            .runExited(step: 0, run: 1, exitCode: 1, detail: nil),
        ])
        #expect(budget.status == .failed)
        #expect(budget.failure?.message == "Reached maximum budget ($0.0005)")

        // An error turn fails the step even if the process exits 0.
        let (errorTurn, _) = run(newTask(), [
            .begin, .workspaceReady(ws), launched(0),
            .runEvents(step: 0, run: 1, events: [.turnFinished(TurnSummary(isError: true, kind: "error_x"))], offset: 5),
            .runExited(step: 0, run: 1, exitCode: 0, detail: nil),
        ])
        #expect(errorTurn.failure?.message == "error_x")
    }

    @Test func exitCodesAreExplained() {
        #expect(describeExit(143) == "The agent was ended by SIGTERM (exit 143), not by Topside.")
        #expect(describeExit(1) == "The agent exited with code 1.")
        let (t, _) = run(newTask(), [.begin, .workspaceReady(ws), launched(0),
                                     .runExited(step: 0, run: 1, exitCode: 137, detail: nil)])
        #expect(t.failure?.message == "The agent was ended by SIGKILL (exit 137), not by Topside.")
    }

    @Test func workspaceFailureAndLaunchFailure() {
        let (w, _) = run(newTask(), [.begin, .workspaceFailed(message: "npm ci failed", detail: "ERR")])
        #expect(w.status == .failed && w.failure?.kind == .workspace && w.failure?.detail == "ERR")

        let (l, _) = run(newTask(), [.begin, .workspaceReady(ws), .launchFailed(step: 0, message: "not installed")])
        #expect(l.status == .failed && l.failure?.kind == .agent)
    }

    @Test func pauseOnlyWhileRunningAndDiscardCloses() {
        let (queued, _) = run(newTask(), [.pausedChanged(true)])
        #expect(queued.paused == false)

        let (t, _) = run(newTask(), [.begin, .workspaceReady(ws), launched(0), .pausedChanged(true)])
        #expect(t.paused)
        let (closed, _) = reduce(t, .discarded, now: t0)
        #expect(closed.status == .closed && closed.outcome == .discarded && !closed.paused)
    }

    @Test func recoveryEffects() {
        let (afterReady, _) = run(newTask(), [.begin, .workspaceReady(ws)])
        #expect(TopsideCore.recoveryEffects(for: afterReady) == [.launch(step: 0)])

        let (afterExit, _) = run(newTask(), [.begin, .workspaceReady(ws), launched(0),
                                             .runExited(step: 0, run: 1, exitCode: 0, detail: nil)])
        #expect(TopsideCore.recoveryEffects(for: afterExit) == [.computeResult])

        let (live, _) = run(newTask(), [.begin, .workspaceReady(ws), launched(0)])
        #expect(TopsideCore.recoveryEffects(for: live).isEmpty)   // engine re-attaches instead
    }

    @Test func urgencyOrder() {
        let sorted = TaskStatus.allCases.shuffled().sorted { $0.urgency < $1.urgency }
        #expect(sorted == [.needsYou, .failed, .ready, .running, .queued, .closed])
    }
}
