import Darwin
import Foundation
import TopsideCore

public struct TaskRequest: Codable, Sendable, Equatable {
    public var prompt: String
    public var repo: String
    public var agent: AgentKind
    public var mode: WorkspaceMode
    public var model: String?
    public var budgetUSD: Double?

    public init(prompt: String, repo: String, agent: AgentKind, mode: WorkspaceMode = .isolated,
                model: String? = nil, budgetUSD: Double? = nil) {
        self.prompt = prompt
        self.repo = repo
        self.agent = agent
        self.mode = mode
        self.model = model
        self.budgetUSD = budgetUSD
    }
}

public struct EngineError: Error, CustomStringConvertible, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Runs tasks: schedules them, prepares workspaces, starts and follows agent
/// processes, and computes results. Every state change goes through the pure
/// `reduce` in TopsideCore; this actor only does the I/O around it.
///
/// Agent processes are detached: if the engine stops, they keep running, and a
/// new engine on the same data directory re-attaches to them (`start()`).
public actor TaskEngine {
    nonisolated public let configuration: EngineConfiguration
    nonisolated public let workspaces: WorkspaceManager
    nonisolated public let store: TaskStore
    let repoConfigs: RepoConfigStore
    let runners: [AgentKind: any AgentRunner]

    private var tasks: [TaskID: TopsideTask] = [:]
    private var watchers: [TaskID: RunWatcher] = [:]
    private var subscribers: [UUID: AsyncStream<TopsideTask>.Continuation] = [:]
    private var installations: [AgentKind: AgentInstallation] = [:]
    private var logger: (@Sendable (String) -> Void)?
    /// Tasks whose in-memory state is ahead of disk only by run events.
    private var unsaved: Set<TaskID> = []
    private var flushScheduled = false

    public init(configuration: EngineConfiguration, runners: [any AgentRunner]) throws {
        self.configuration = configuration
        self.store = try TaskStore(root: configuration.dataDirectory)
        self.repoConfigs = RepoConfigStore(root: configuration.dataDirectory)
        let git = try Git.locate(searchPath: configuration.environment["PATH"], environment: configuration.environment)
        try FileManager.default.createDirectory(at: configuration.worktreesRoot, withIntermediateDirectories: true)
        self.workspaces = WorkspaceManager(git: git, worktreesRoot: configuration.worktreesRoot,
                                           environment: configuration.environment)
        self.runners = Dictionary(runners.map { ($0.kind, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func setLogger(_ logger: (@Sendable (String) -> Void)?) {
        self.logger = logger
    }

    private func log(_ message: String) { logger?(message) }

    // MARK: Startup and recovery

    /// Load saved tasks, re-attach to agents that are still running, finish
    /// what was interrupted, and start waiting tasks.
    public func start() {
        for t in store.loadAll() where tasks[t.id] == nil { tasks[t.id] = t }
        for t in tasks.values where !t.status.isSettled {
            if t.status == .queued, t.startedAt != nil, t.workspace == nil {
                handle(t.id, .workspaceFailed(message: "Topside stopped while the workspace was being prepared.",
                                              detail: nil))
                continue
            }
            if let step = t.currentStep, let run = t.steps[step].runs.last, !run.isFinished {
                // Alive: follow it from where we left off. Gone: the watcher drains the
                // remaining output and reads the recorded exit code.
                follow(t.id, step: step, run: run)
                log("\(t.shortID) re-attached to run \(step)-\(run.number)")
                continue
            }
            for effect in recoveryEffects(for: t) { perform(effect, for: t.id) }
        }
        schedule()
    }

    /// Stop following processes without touching them, as if the app quit.
    public func detach() {
        flush()
        for w in watchers.values { w.cancel() }
        watchers.removeAll()
        for s in subscribers.values { s.finish() }
        subscribers.removeAll()
    }

    // MARK: Queries

    public func task(_ id: TaskID) -> TopsideTask? { tasks[id] }

    public func allTasks() -> [TopsideTask] {
        tasks.values.sorted { ($0.status.urgency, $1.createdAt) < ($1.status.urgency, $0.createdAt) }
    }

    public func updates() -> AsyncStream<TopsideTask> {
        let (stream, continuation) = AsyncStream.makeStream(of: TopsideTask.self)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    /// Wait until the task settles (ready / failed / closed) or the timeout passes.
    public func waitUntilSettled(_ id: TaskID, timeout: Double) async -> TopsideTask? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let t = tasks[id], t.status.isSettled { return t }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return tasks[id]
    }

    public func installation(for kind: AgentKind) -> AgentInstallation? {
        if let cached = installations[kind] { return cached }
        guard let found = runners[kind]?.detect(searchPath: configuration.environment["PATH"]) else { return nil }
        installations[kind] = found
        return found
    }

    // MARK: Commands

    public func submit(_ request: TaskRequest) throws -> TopsideTask {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw EngineError("The prompt is empty.") }
        guard runners[request.agent] != nil else { throw EngineError("Unknown agent: \(request.agent)") }
        guard installation(for: request.agent) != nil else {
            throw EngineError("\(runners[request.agent]!.displayName) is not installed (could not find its command).")
        }
        let repo = URL(fileURLWithPath: request.repo).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo, isDirectory: &isDir), isDir.boolValue else {
            throw EngineError("No such directory: \(repo)")
        }
        let task = TopsideTask(prompt: prompt, repo: repo, agent: request.agent, model: request.model,
                               budgetUSD: request.budgetUSD, mode: request.mode,
                               setup: repoConfigs.setup(for: repo))
        tasks[task.id] = task
        persist(task)
        publish(task)
        log("\(task.shortID) submitted: \(task.title)")
        schedule()
        return tasks[task.id]!
    }

    public func stop(_ id: TaskID) throws {
        guard let t = tasks[id] else { throw EngineError("No such task.") }
        guard !t.status.isSettled else { return }
        handle(id, .interruptRequested(.user))
        if let (pid, start) = liveProcess(of: t) {
            if t.paused { ProcessSupervisor.signal(pid: pid, startTime: start, SIGCONT) }
            escalate(pid: pid, start: start)
        }
    }

    /// Stop the task if needed, remove its worktree and branch, and close it.
    public func discard(_ id: TaskID) async throws {
        guard let t = tasks[id] else { throw EngineError("No such task.") }
        guard t.status != .closed else { return }
        if t.status == .queued, t.startedAt != nil, t.workspace == nil {
            throw EngineError("The workspace is still being prepared; try again when it is ready.")
        }
        if let (pid, start) = liveProcess(of: t) {
            if !t.status.isSettled { handle(id, .interruptRequested(.engine)) }
            await terminate(pid: pid, start: start)
        }
        if let ws = tasks[id]?.workspace, t.mode == .isolated {
            do {
                try await workspaces.remove(ws, repo: t.repo)
            } catch {
                throw EngineError("Could not remove the worktree: \(error)")
            }
        }
        watchers[id]?.cancel()
        watchers[id] = nil
        handle(id, .discarded)
        log("\(t.shortID) discarded")
        schedule()
    }

    /// Pause or resume a running task (SIGSTOP / SIGCONT to its process group).
    public func setPaused(_ id: TaskID, _ paused: Bool) throws {
        guard let t = tasks[id] else { throw EngineError("No such task.") }
        guard t.status == .running, let (pid, start) = liveProcess(of: t) else {
            if paused { throw EngineError("Only a task with a running agent can be paused.") }
            return
        }
        ProcessSupervisor.signal(pid: pid, startTime: start, paused ? SIGSTOP : SIGCONT)
        handle(id, .pausedChanged(paused))
    }

    public func setAllPaused(_ paused: Bool) {
        for t in tasks.values where t.status == .running && t.paused != paused {
            try? setPaused(t.id, paused)
        }
    }

    // MARK: State transitions

    private func handle(_ id: TaskID, _ event: TaskEvent) {
        guard let before = tasks[id] else { return }
        let (after, effects) = reduce(before, event, now: Date())
        guard after != before || !effects.isEmpty else { return }
        tasks[id] = after
        if case .runEvents = event, after.status == before.status {
            // Activity, summaries and the read offset: batch to one write every 3 s
            // (M1 profiling: per-event atomic writes were the engine's main CPU cost).
            // Safe after a crash: state and offset are saved together, so the events
            // past the saved offset are simply read and applied again.
            persistSoon(id)
        } else {
            unsaved.remove(id)
            persist(after)
        }
        publish(after)
        if after.status != before.status {
            log("\(after.shortID) \(before.status.rawValue) → \(after.status.rawValue)"
                + (after.failure.map { ": \($0.message)" } ?? ""))
        }
        for effect in effects { perform(effect, for: id) }
        if before.isActive && !after.isActive { schedule() }
    }

    private func persist(_ task: TopsideTask) {
        do { try store.save(task) } catch { log("could not save \(task.shortID): \(error)") }
    }

    private func persistSoon(_ id: TaskID) {
        unsaved.insert(id)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        for id in unsaved { if let t = tasks[id] { persist(t) } }
        unsaved.removeAll()
    }

    private func publish(_ task: TopsideTask) {
        for s in subscribers.values { s.yield(task) }
    }

    /// Start waiting tasks while there is room. No limit unless configured (D5).
    /// In-place tasks on the same repository run one at a time.
    private func schedule() {
        var room = configuration.maxConcurrent.map { $0 - tasks.values.filter(\.isActive).count } ?? Int.max
        let waiting = tasks.values.filter { $0.status == .queued && $0.startedAt == nil && !$0.stopRequested }
            .sorted { $0.createdAt < $1.createdAt }
        for t in waiting where room > 0 {
            if t.mode == .inPlace, tasks.values.contains(where: {
                $0.id != t.id && $0.mode == .inPlace && $0.repo == t.repo && $0.isActive
            }) { continue }
            handle(t.id, .begin)
            room -= 1
        }
    }

    private func perform(_ effect: TaskEffect, for id: TaskID) {
        switch effect {
        case .prepareWorkspace:
            guard let task = tasks[id] else { return }
            let workspaces = self.workspaces
            let log = store.prepLog(task: id)
            Task {
                do {
                    let info = try await workspaces.prepare(task, log: log)
                    self.handle(id, .workspaceReady(info))
                } catch let e as WorkspaceError {
                    self.handle(id, .workspaceFailed(message: e.message, detail: e.detail))
                } catch {
                    self.handle(id, .workspaceFailed(message: "\(error)", detail: nil))
                }
            }

        case .launch(let step):
            launch(id, step: step)

        case .computeResult:
            guard let task = tasks[id], let ws = task.workspace else { return }
            let workspaces = self.workspaces
            Task {
                do {
                    let files = try await workspaces.changeSet(ws)
                    let summary = task.steps.flatMap(\.runs).last?.summary
                    self.handle(id, .resultComputed(TaskResult(files: files, summary: summary,
                                                               costUSD: task.totalCostUSD,
                                                               permissionDenials: task.totalPermissionDenials)))
                } catch {
                    self.handle(id, .resultFailed("\(error)"))
                }
            }
        }
    }

    // MARK: Runs

    private func launch(_ id: TaskID, step: Int) {
        guard let task = tasks[id], let ws = task.workspace, task.recipe.steps.indices.contains(step) else { return }
        guard case .agent(let agentStep) = task.recipe.steps[step] else {
            handle(id, .launchFailed(step: step, message: "The \(task.recipe.steps[step].label) step is not supported yet."))
            return
        }
        guard let runner = runners[task.agent], let install = installation(for: task.agent) else {
            handle(id, .launchFailed(step: step, message: "\(task.agent) is not installed."))
            return
        }
        let previous = task.steps[step].runs.last
        let number = (previous?.number ?? 0) + 1
        let request = AgentLaunchRequest(
            prompt: agentStep.promptTemplate.replacingOccurrences(of: "{{prompt}}", with: task.prompt),
            workspacePath: ws.path, access: agentStep.access, resumeSessionID: previous?.sessionID,
            model: task.model, budgetUSD: task.budgetUSD)
        let spec = runner.launchSpec(for: request, executable: install.executable,
                                     baseEnvironment: configuration.environment)
        let dir = store.runDirectory(task: id, step: step, run: number)
        do {
            let launched = try ProcessSupervisor.spawnDetached(spec, runDirectory: dir)
            var record = RunRecord(number: number, directory: dir.path, launchedAt: Date())
            record.pid = launched.pid
            record.processStartTime = launched.startTime
            if runner.capabilities.contains(.presetSessionID) {
                record.sessionID = request.resumeSessionID ?? request.newSessionID
            }
            handle(id, .runLaunched(step: step, record))
            follow(id, step: step, run: record)
            log("\(task.shortID) started \(runner.displayName) (pid \(launched.pid)) in \(ws.path)")
        } catch {
            handle(id, .launchFailed(step: step, message: "Could not start \(runner.displayName): \(error)"))
        }
    }

    private func follow(_ id: TaskID, step: Int, run: RunRecord) {
        guard let pid = run.pid, let start = run.processStartTime,
              let runner = tasks[id].flatMap({ runners[$0.agent] }) else {
            handle(id, .runExited(step: step, run: run.number, exitCode: nil, detail: "No process was recorded."))
            return
        }
        let dir = URL(fileURLWithPath: run.directory)
        let watcher = RunWatcher(directory: dir, pid: pid, startTime: start, offset: run.eventsOffset)
        watchers[id]?.cancel()
        watchers[id] = watcher
        Task {
            for await output in watcher.stream {
                switch output {
                case .lines(let lines, let end):
                    let events = lines.flatMap { runner.parse(line: $0) }
                    self.handle(id, .runEvents(step: step, run: run.number, events: events, offset: end))
                case .exited(let code):
                    self.handle(id, .runExited(step: step, run: run.number, exitCode: code,
                                               detail: ProcessSupervisor.stderrTail(in: dir)))
                }
            }
            if self.watchers[id] === watcher { self.watchers[id] = nil }
        }
        watcher.start()
    }

    private func liveProcess(of task: TopsideTask) -> (Int32, Double)? {
        guard let run = task.currentRun, !run.isFinished, let pid = run.pid, let start = run.processStartTime,
              ProcessSupervisor.isAlive(pid: pid, startTime: start) else { return nil }
        return (pid, start)
    }

    /// SIGINT now; SIGTERM, then SIGKILL, if it is still running after each grace period.
    private func escalate(pid: Int32, start: Double) {
        ProcessSupervisor.signal(pid: pid, startTime: start, SIGINT)
        let grace = configuration.stopGracePeriod
        Task.detached {
            for sig in [SIGTERM, SIGKILL] {
                try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                guard ProcessSupervisor.isAlive(pid: pid, startTime: start) else { return }
                ProcessSupervisor.signal(pid: pid, startTime: start, sig)
            }
        }
    }

    /// SIGTERM, wait briefly, SIGKILL. Returns once the process is gone (or after ~5 s).
    private func terminate(pid: Int32, start: Double) async {
        ProcessSupervisor.signal(pid: pid, startTime: start, SIGCONT)
        ProcessSupervisor.signal(pid: pid, startTime: start, SIGTERM)
        for _ in 0..<30 where ProcessSupervisor.isAlive(pid: pid, startTime: start) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        ProcessSupervisor.signal(pid: pid, startTime: start, SIGKILL)
        for _ in 0..<20 where ProcessSupervisor.isAlive(pid: pid, startTime: start) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
