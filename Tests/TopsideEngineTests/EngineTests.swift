import Darwin
import Foundation
import Testing
import TopsideCore
@testable import TopsideEngine
import TopsideRunners

@Suite(.timeLimit(.minutes(3))) struct EngineLifecycleTests {
    @Test func claudeTaskRunsInAWorktreeAndProducesAResult() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let record = box.root.appendingPathComponent("agent-record.txt").path
        let before = try box.mainCheckout()
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_WRITE": "src/new.txt",
                                     "FAKE_AGENT_RECORD": record])
        await engine.start()

        let submitted = try await engine.submit(TaskRequest(prompt: "-Add a file\nwith details", repo: box.repo,
                                                            agent: .claudeCode))
        #expect(submitted.title == "-Add a file")
        let t = try await settled(engine, submitted.id)

        #expect(t.status == .ready, "\(t.failure?.message ?? "")")
        let ws = try #require(t.workspace)
        #expect(ws.branch?.hasPrefix("topside/add-a-file-") == true)
        #expect(ws.path.hasPrefix(box.worktrees.path))
        #expect(FileManager.default.fileExists(atPath: ws.path + "/src/new.txt"))
        #expect(t.result?.files == [FileChange(path: "src/new.txt", added: 2, deleted: 0)])
        #expect(t.result?.summary == "DONE")
        #expect((t.result?.costUSD ?? 0) > 0)
        let run = try #require(t.currentRun)
        #expect(run.exitCode == 0)
        #expect(run.sessionID != nil)

        // The main checkout is untouched.
        #expect(try box.mainCheckout() == before)

        // The agent got the prompt on stdin (not argv), ran in the worktree, with the expected flags.
        let seen = try String(contentsOfFile: record, encoding: .utf8)
        #expect(seen.contains("stdin: -Add a file\nwith details"))
        #expect(seen.contains("cwd: \(URL(fileURLWithPath: ws.path).resolvingSymlinksInPath().path)")
                || seen.contains("cwd: \(ws.path)"))
        #expect(seen.contains("--session-id \(run.sessionID!)"))
        #expect(!seen.contains("argv: -Add"))

        // Saved state matches memory.
        #expect(engine.store.load(t.id) == t)
    }

    @Test func codexTaskReadsItsOwnFormat() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.codexResume])
        await engine.start()
        let t = try await settled(engine, try await engine.submit(TaskRequest(prompt: "explain", repo: box.repo,
                                                                              agent: .codex)).id)
        #expect(t.status == .ready)
        #expect(t.result?.files.isEmpty == true)   // a question, not a change: a valid result
        #expect(t.result?.summary?.contains("Operation not permitted") == true)
        #expect(t.currentRun?.sessionID == "01a1e34d-00d4-76e3-be08-a95894e99563")
    }

    @Test func agentErrorFailsTheTask() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeBudget, "FAKE_AGENT_EXIT": "1"])
        await engine.start()
        let t = try await settled(engine, try await engine.submit(TaskRequest(prompt: "x", repo: box.repo,
                                                                              agent: .claudeCode)).id)
        #expect(t.status == .failed)
        #expect(t.failure?.kind == .agent)
        #expect(t.failure?.message == "Reached maximum budget ($0.0005)")
    }

    @Test func stopInterruptsARunningAgent() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_HANG": "30"])
        await engine.start()
        let id = try await engine.submit(TaskRequest(prompt: "x", repo: box.repo, agent: .claudeCode)).id
        let live = try await running(engine, id)
        let started = Date()
        try await engine.stop(id)
        let t = try await settled(engine, id)
        #expect(t.status == .failed && t.failure?.kind == .stopped)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!ProcessSupervisor.isAlive(pid: live.currentRun!.pid!, startTime: live.currentRun!.processStartTime!))
    }

    @Test func killedAgentFailsTheTask() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_HANG": "30"])
        await engine.start()
        let id = try await engine.submit(TaskRequest(prompt: "x", repo: box.repo, agent: .claudeCode)).id
        let pid = try await running(engine, id).currentRun!.pid!
        killpg(pid, SIGKILL)   // kill -9, from outside Topside
        let t = try await settled(engine, id)
        #expect(t.status == .failed)
        #expect(t.failure?.kind == .lost)
    }

    @Test func discardRemovesTheWorktreeAndBranch() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let before = try box.mainCheckout()
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_WRITE": "x.txt"])
        await engine.start()
        let t = try await settled(engine, try await engine.submit(TaskRequest(prompt: "x", repo: box.repo,
                                                                              agent: .claudeCode)).id)
        let ws = try #require(t.workspace)
        try await engine.discard(t.id)
        let closed = try #require(await engine.task(t.id))
        #expect(closed.status == .closed && closed.outcome == .discarded)
        #expect(!FileManager.default.fileExists(atPath: ws.path))
        #expect(try sh("git branch --list 'topside/*'", in: box.repo).isEmpty)
        #expect(try box.mainCheckout() == before)
    }

    /// A repository straight after `git init`: isolated tasks get an orphan
    /// branch, and changes are measured against the empty tree.
    @Test func repositoryWithNoCommitsYet() async throws {
        let box = try Sandbox(commits: false)
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_WRITE": "data.json"])
        await engine.start()

        let t = try await settled(engine, try await engine.submit(TaskRequest(prompt: "x", repo: box.repo,
                                                                              agent: .claudeCode)).id)
        #expect(t.status == .ready, "\(t.failure?.message ?? "")")
        let ws = try #require(t.workspace)
        #expect(ws.branch?.hasPrefix("topside/") == true)
        #expect(t.result?.files == [FileChange(path: "data.json", added: 2, deleted: 0)])
        // The user's checkout is still empty, still without a commit.
        #expect(try sh("git status --porcelain", in: box.repo).isEmpty)
        #expect((try? sh("git rev-parse --verify -q HEAD", in: box.repo)) == nil)

        try await engine.discard(t.id)
        #expect(!FileManager.default.fileExists(atPath: ws.path))
        #expect(try sh("git worktree list --porcelain | grep -c '^worktree' || true", in: box.repo) == "1")

        let inPlace = try await settled(engine, try await engine.submit(
            TaskRequest(prompt: "y", repo: box.repo, agent: .claudeCode, mode: .inPlace)).id)
        #expect(inPlace.status == .ready, "\(inPlace.failure?.message ?? "")")
        #expect(inPlace.result?.files == [FileChange(path: "data.json", added: 2, deleted: 0)])
    }

    @Test func discardWhileRunningStopsTheAgentFirst() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_HANG": "30"])
        await engine.start()
        let id = try await engine.submit(TaskRequest(prompt: "x", repo: box.repo, agent: .claudeCode)).id
        let live = try await running(engine, id)
        try await engine.discard(id)
        #expect(await engine.task(id)?.status == .closed)
        #expect(!ProcessSupervisor.isAlive(pid: live.currentRun!.pid!, startTime: live.currentRun!.processStartTime!))
        #expect(!FileManager.default.fileExists(atPath: live.workspace!.path))
    }

    @Test func pauseAndResume() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_HANG": "1"])
        await engine.start()
        let id = try await engine.submit(TaskRequest(prompt: "x", repo: box.repo, agent: .claudeCode)).id
        _ = try await running(engine, id)
        try await engine.setPaused(id, true)
        #expect(await engine.task(id)?.paused == true)
        try await Task.sleep(nanoseconds: 2_000_000_000)        // longer than the agent's 1 s hang
        #expect(await engine.task(id)?.status == .running)      // still stopped
        try await engine.setPaused(id, false)
        let t = try await settled(engine, id)
        #expect(t.status == .ready && !t.paused)
    }
}

@Suite(.timeLimit(.minutes(3))) struct EngineRestartTests {
    @Test func reattachesToARunningAgentAfterARestart() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let fake = ["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_HANG": "2", "FAKE_AGENT_DELAY": "0.05"]
        let first = try box.engine(fake)
        await first.start()
        let id = try await first.submit(TaskRequest(prompt: "x", repo: box.repo, agent: .claudeCode)).id
        let live = try await running(first, id)
        // Not a descendant of the engine: a tool that kills the engine's whole
        // process tree must not take the agent with it.
        #expect(parentPID(of: live.currentRun!.pid!) == 1)
        await first.detach()   // the app quits; the agent keeps going

        #expect(ProcessSupervisor.isAlive(pid: live.currentRun!.pid!, startTime: live.currentRun!.processStartTime!))
        let second = try box.engine(fake)
        await second.start()
        let t = try await settled(second, id)
        #expect(t.status == .ready)
        #expect(t.currentRun?.turnCount == 1)   // no event applied twice
        #expect(t.result?.summary == "DONE")
    }

    @Test func picksUpARunThatFinishedWhileNoEngineWasRunning() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let fake = ["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_HANG": "1"]
        let first = try box.engine(fake)
        await first.start()
        let id = try await first.submit(TaskRequest(prompt: "x", repo: box.repo, agent: .claudeCode)).id
        let live = try await running(first, id)
        await first.detach()
        while ProcessSupervisor.isAlive(pid: live.currentRun!.pid!, startTime: live.currentRun!.processStartTime!) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let second = try box.engine(fake)
        await second.start()
        let t = try await settled(second, id)
        #expect(t.status == .ready)
        #expect(t.currentRun?.exitCode == 0)
        #expect(t.currentRun?.turnCount == 1)
    }
}

@Suite(.timeLimit(.minutes(5))) struct EngineSchedulingTests {
    @Test func fiftyTasksRunAtOnce() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_HANG": "1",
                                     "FAKE_AGENT_WRITE": "out.txt"])
        await engine.start()
        let started = Date()
        var ids: [TaskID] = []
        for i in 0..<50 {
            ids.append(try await engine.submit(TaskRequest(prompt: "task \(i)", repo: box.repo, agent: .claudeCode)).id)
        }
        // No limit by default: all start without waiting for a slot.
        #expect(await engine.allTasks().allSatisfy { $0.startedAt != nil })
        var finished: [TopsideTask] = []
        for id in ids { finished.append(try await settled(engine, id, timeout: 120)) }
        let failures = finished.filter { $0.status != .ready }.map { "\($0.title): \($0.failure?.message ?? "")" }
        #expect(failures.isEmpty, "\(failures.prefix(3))")
        #expect(Set(finished.compactMap(\.workspace?.path)).count == 50)
        let elapsed = Date().timeIntervalSince(started)
        print("50 tasks finished in \(String(format: "%.1f", elapsed)) s")
        #expect(elapsed < 60)
    }

    /// M1 completion criterion: with 50 agents running, the engine itself stays
    /// under 5% of one core. Measured over the steady phase (all 50 running and
    /// streaming events), using this process's own CPU time.
    /// Off by default: CPU time is per process, so other tests running in parallel
    /// would be counted. Run alone with `TOPSIDE_PERF=1 swift test --filter engineCPU`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOPSIDE_PERF"] == "1"), .serialized,
          arguments: [("1.0", 5.0), ("0.2", 10.0)])
    func engineCPUWithFiftyRunningAgents(delay: String, limit: Double) async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        // Each fake agent streams its 23 events, one every `delay` seconds:
        // 1.0 is about as busy as a real agent gets; 0.2 is a stress load (250 events/s in total).
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_DELAY": delay])
        await engine.start()
        var ids: [TaskID] = []
        for i in 0..<50 {
            ids.append(try await engine.submit(TaskRequest(prompt: "task \(i)", repo: box.repo, agent: .claudeCode)).id)
        }
        for id in ids { _ = try await running(engine, id) }

        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let cpu0 = cpuSeconds(), wall0 = Date()
        try await Task.sleep(nanoseconds: 3_000_000_000)   // sample the steady phase
        let percent = (cpuSeconds() - cpu0) / Date().timeIntervalSince(wall0) * 100
        print(String(format: "engine CPU with 50 running agents, one event every %@ s each: %.1f%% of one core",
                     delay, percent))
        #expect(percent < limit)

        for id in ids { #expect(try await settled(engine, id, timeout: 90).status == .ready) }
    }

    @Test func optionalLimitIsRespected() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_HANG": "1"], maxConcurrent: 2)
        await engine.start()
        let updates = await engine.updates()
        let watcher = Task {
            var peak = 0
            var latest: [TaskID: TopsideTask] = [:]
            for await t in updates {
                latest[t.id] = t
                peak = max(peak, latest.values.filter(\.isActive).count)
                if latest.count == 4 && latest.values.allSatisfy(\.status.isSettled) { break }
            }
            return peak
        }
        var ids: [TaskID] = []
        for i in 0..<4 { ids.append(try await engine.submit(TaskRequest(prompt: "t\(i)", repo: box.repo, agent: .claudeCode)).id) }
        for id in ids { #expect(try await settled(engine, id).status == .ready) }
        #expect(await watcher.value == 2)
    }

    @Test func inPlaceTasksOnOneRepoRunOneAtATime() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow, "FAKE_AGENT_HANG": "1"])
        await engine.start()
        let a = try await engine.submit(TaskRequest(prompt: "a", repo: box.repo, agent: .claudeCode, mode: .inPlace)).id
        let b = try await engine.submit(TaskRequest(prompt: "b", repo: box.repo, agent: .claudeCode, mode: .inPlace)).id
        _ = try await running(engine, a)
        #expect(await engine.task(b)?.startedAt == nil)   // waits for a
        #expect(try await settled(engine, a).workspace?.path == box.repo)
        #expect(try await settled(engine, b).status == .ready)
    }
}

@Suite(.timeLimit(.minutes(2))) struct EngineWorkspaceSetupTests {
    @Test func copiesUntrackedFilesAndRunsThePrepCommand() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try "API_URL=http://localhost\n".write(toFile: box.repo + "/.env", atomically: true, encoding: .utf8)
        try RepoConfigStore(root: box.data).save(
            RepoSetup(copyFiles: [".env", "../escape", "missing.txt"], prepCommand: "test -f .env && touch prep-ran.txt"),
            for: box.repo)
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow])
        await engine.start()
        let t = try await settled(engine, try await engine.submit(TaskRequest(prompt: "x", repo: box.repo,
                                                                              agent: .claudeCode)).id)
        #expect(t.status == .ready, "\(t.failure?.message ?? "") \(t.failure?.detail ?? "")")
        let ws = try #require(t.workspace?.path)
        #expect(FileManager.default.fileExists(atPath: ws + "/.env"))
        #expect(!FileManager.default.fileExists(atPath: box.root.appendingPathComponent("escape").path))
        // .env is gitignored, so it is not a change; prep-ran.txt is.
        #expect(t.result?.files.map(\.path) == ["prep-ran.txt"])
        let log = try String(contentsOf: engine.store.prepLog(task: t.id), encoding: .utf8)
        #expect(log.contains("copied .env") && log.contains("skipped ../escape") && log.contains("skipped missing.txt"))
    }

    @Test func failingPrepFailsTheTask() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try RepoConfigStore(root: box.data).save(RepoSetup(prepCommand: "echo broken >&2; exit 3"), for: box.repo)
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow])
        await engine.start()
        let t = try await settled(engine, try await engine.submit(TaskRequest(prompt: "x", repo: box.repo,
                                                                              agent: .claudeCode)).id)
        #expect(t.status == .failed && t.failure?.kind == .workspace)
        #expect(t.failure?.detail?.contains("broken") == true)
        #expect(t.currentRun == nil)   // the agent never started
    }

    @Test func rejectsBadSubmissions() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine()
        await #expect(throws: EngineError("The prompt is empty.")) {
            try await engine.submit(TaskRequest(prompt: "  \n", repo: box.repo, agent: .claudeCode))
        }
        await #expect(throws: EngineError.self) {
            try await engine.submit(TaskRequest(prompt: "x", repo: "/no/such/dir", agent: .claudeCode))
        }
        await #expect(throws: EngineError("Unknown agent: other")) {
            try await engine.submit(TaskRequest(prompt: "x", repo: box.repo, agent: AgentKind("other")))
        }
        // A directory that is not a git repository fails at preparation, with a clear message.
        let plain = box.root.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let t = try await settled(engine, try await engine.submit(TaskRequest(prompt: "x", repo: plain, agent: .claudeCode)).id)
        #expect(t.failure?.kind == .workspace)
    }
}

@Suite struct ControlTests {
    @Test func cliProtocolRoundTrip() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let engine = try box.engine(["FAKE_AGENT_FIXTURE": Paths.claudeAllow])
        await engine.start()
        let path = "/tmp/topside-ctl-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(engine: engine, path: path)
        try server.start()
        defer { server.stop() }

        #expect(try await ControlClient.send(ControlRequest(action: .ping), socketPath: path).ok)
        let reply = try await ControlClient.send(ControlRequest(action: .submit, submit: TaskRequest(
            prompt: "via socket", repo: box.repo, agent: .claudeCode)), socketPath: path)
        let id = try #require(reply.task?.id)
        #expect(try await settled(engine, id).status == .ready)
        let bad = try await ControlClient.send(ControlRequest(action: .stop), socketPath: path)
        #expect(!bad.ok && bad.error == "Missing task id.")
    }
}
