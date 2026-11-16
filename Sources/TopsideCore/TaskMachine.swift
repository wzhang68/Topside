import Foundation

/// Everything that can happen to a task. The engine turns process output,
/// git operations and user actions into these, and feeds them to `reduce`.
public enum TaskEvent: Sendable, Equatable {
    /// The scheduler gave the task a slot.
    case begin
    case workspaceReady(WorkspaceInfo)
    case workspaceFailed(message: String, detail: String?)
    case runLaunched(step: Int, RunRecord)
    /// Events parsed from the run's output. `offset` is the end of the consumed bytes.
    case runEvents(step: Int, run: Int, events: [RunEvent], offset: UInt64)
    /// `exitCode` is nil when the process vanished without recording one (e.g. SIGKILL).
    case runExited(step: Int, run: Int, exitCode: Int32?, detail: String?)
    case launchFailed(step: Int, message: String)
    /// Recorded *before* the engine sends a signal, so the exit is attributed correctly.
    case interruptRequested(Interruption)
    case resultComputed(TaskResult)
    case resultFailed(String)
    case pausedChanged(Bool)
    case discarded
}

/// Work the engine must do after a transition.
public enum TaskEffect: Sendable, Equatable {
    case prepareWorkspace
    case launch(step: Int)
    case computeResult
}

/// The task state machine (design doc 7.4). Pure: no I/O, no clock.
///
/// It is deliberately forgiving: events that arrive late, twice, or for a
/// run that is no longer current are ignored rather than treated as errors,
/// because process output and exit notifications can race.
public func reduce(_ task: TopsideTask, _ event: TaskEvent, now: Date) -> (TopsideTask, [TaskEffect]) {
    var t = task
    var effects: [TaskEffect] = []
    defer { t.updatedAt = now }

    func fail(_ kind: FailureKind, _ message: String, _ detail: String? = nil) {
        t.status = .failed
        t.failure = Failure(kind: kind, message: message, detail: detail)
        t.paused = false
    }

    switch event {
    case .begin:
        guard t.startedAt == nil, t.status == .queued else { break }
        if t.stopRequested {
            fail(.stopped, "Stopped before it started.")
            break
        }
        t.startedAt = now
        effects.append(.prepareWorkspace)

    case .workspaceReady(let info):
        guard t.status == .queued, t.workspace == nil else { break }
        t.workspace = info
        if t.stopRequested {
            fail(.stopped, "Stopped while the workspace was being prepared.")
            break
        }
        guard !t.steps.isEmpty else {
            effects.append(.computeResult)
            t.status = .running
            break
        }
        t.currentStep = 0
        t.status = .running
        effects.append(.launch(step: 0))

    case .workspaceFailed(let message, let detail):
        guard !t.status.isSettled else { break }
        fail(.workspace, message, detail)

    case .runLaunched(let step, let record):
        guard t.status == .running, t.currentStep == step, t.steps.indices.contains(step) else { break }
        t.steps[step].status = .running
        t.steps[step].runs.append(record)

    case .launchFailed(let step, let message):
        guard t.status == .running, t.currentStep == step else { break }
        t.steps[step].status = .failed
        fail(.agent, message)

    case .runEvents(let step, let run, let events, let offset):
        guard t.steps.indices.contains(step),
              let i = t.steps[step].runs.firstIndex(where: { $0.number == run }) else { break }
        var r = t.steps[step].runs[i]
        guard offset > r.eventsOffset else { break }   // already applied
        for e in events { apply(e, to: &r) }
        r.eventsOffset = offset
        t.steps[step].runs[i] = r

    case .runExited(let step, let run, let exitCode, let detail):
        guard t.steps.indices.contains(step),
              let i = t.steps[step].runs.firstIndex(where: { $0.number == run }),
              !t.steps[step].runs[i].isFinished else { break }
        t.steps[step].runs[i].endedAt = now
        t.steps[step].runs[i].exitCode = exitCode
        t.steps[step].runs[i].activity = nil
        t.steps[step].runs[i].activeSubagents = []
        let r = t.steps[step].runs[i]
        // Only the current run of the current step can move the task.
        guard t.currentStep == step, i == t.steps[step].runs.count - 1, !t.status.isSettled else { break }

        if let who = r.interruption {
            t.steps[step].status = .failed
            fail(.stopped, who == .user ? "Stopped." : "Stopped by Topside.")
        } else if exitCode == 0, r.lastTurnIsError != true {
            t.steps[step].status = .succeeded
            let next = step + 1
            if t.steps.indices.contains(next) {
                t.currentStep = next
                effects.append(.launch(step: next))
            } else {
                effects.append(.computeResult)
            }
        } else {
            t.steps[step].status = .failed
            if exitCode == nil {
                fail(.lost, "The agent process ended without reporting an exit code.", detail)
            } else {
                fail(.agent, r.turnErrors.last ?? describeExit(exitCode!), detail)
            }
        }

    case .interruptRequested(let who):
        guard !t.status.isSettled else { break }
        t.stopRequested = true
        if let step = t.currentStep, let last = t.steps[step].runs.indices.last,
           !t.steps[step].runs[last].isFinished {
            t.steps[step].runs[last].interruption = who
        } else if t.startedAt == nil {
            fail(.stopped, "Stopped before it started.")
        }

    case .resultComputed(let result):
        guard t.status == .running else { break }
        t.result = result
        t.status = .ready
        t.paused = false

    case .resultFailed(let message):
        guard t.status == .running else { break }
        fail(.result, "Could not compute the result: \(message)")

    case .pausedChanged(let paused):
        guard t.status == .running || (paused == false && t.paused) else { break }
        t.paused = paused

    case .discarded:
        t.status = .closed
        t.outcome = .discarded
        t.paused = false
    }
    return (t, effects)
}

/// Exit codes above 128 mean the process was ended by a signal (shell convention).
public func describeExit(_ code: Int32) -> String {
    let names: [Int32: String] = [1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 6: "SIGABRT", 9: "SIGKILL",
                                  13: "SIGPIPE", 15: "SIGTERM"]
    if code > 128, let name = names[code - 128] {
        return "The agent was ended by \(name) (exit \(code)), not by Topside."
    }
    return "The agent exited with code \(code)."
}

/// Fold one parsed event into a run record.
public func apply(_ event: RunEvent, to r: inout RunRecord) {
    switch event {
    case .sessionStarted(let id, _):
        if r.sessionID == nil { r.sessionID = id }
    case .toolStarted(_, let name, let detail):
        r.activity = detail.map { "\(name) \($0)" } ?? name
    case .toolFinished:
        break
    case .message(let text):
        r.summary = text
    case .permissionDenied:
        r.permissionDenials += 1
    case .turnFinished(let s):
        r.turnCount += 1
        r.lastTurnIsError = s.isError
        if let text = s.text, !text.isEmpty { r.summary = text }
        if let cost = s.costUSD { r.costUSD = cost }      // cumulative per session
        if let tokens = s.tokens { r.tokens = (r.tokens ?? 0) + tokens }
        if s.isError {
            r.turnErrors.append(s.errors.first ?? s.kind ?? "The agent reported an error.")
        }
        r.activity = nil
    case .subagentStarted(let id, let kind, let description):
        if !r.activeSubagents.contains(where: { $0.id == id }) {
            r.activeSubagents.append(SubagentInfo(id: id, kind: kind, description: description))
        }
    case .subagentFinished(let id, _):
        r.activeSubagents.removeAll { $0.id == id }
    case .notice:
        break
    }
}

/// What still has to happen for a task loaded from disk after a restart,
/// apart from re-attaching to live processes (which only the engine can check).
public func recoveryEffects(for task: TopsideTask) -> [TaskEffect] {
    guard task.status == .running, let step = task.currentStep else { return [] }
    let state = task.steps[step]
    if state.status == .succeeded, step == task.steps.count - 1 { return [.computeResult] }
    if state.status == .pending || (state.status == .running && state.runs.isEmpty) { return [.launch(step: step)] }
    return []
}
