import Darwin
import Foundation
import TopsideCore
import TopsideEngine
import TopsideRunners

// `topside` — the command-line front end to the task engine (milestone M1).

let usage = """
usage: topside <command> [options]

Engine
  serve                     Run the engine in this terminal. Agents keep running if it stops.
  doctor                    Check git, the agents, and whether the engine is running.

Tasks
  run "<prompt>"            Dispatch a task. Reads the prompt from stdin if none is given.
      --repo PATH           Repository (default: the one containing the current directory)
      --agent claude|codex  Agent (default: Claude if installed, else Codex)
      --in-place            Work in the repository's own checkout instead of a new worktree
      --model NAME          Model to ask the agent for
      --budget USD          Claude only: approximate spending cap for the task
      --wait                Wait for the task to finish and show the result
  list [--all]              Tasks, most urgent first (--all includes closed ones)
  show <id>                 Details of one task
  logs <id> [--follow]      What the agent did
  stop <id>                 Interrupt the agent (the worktree is kept)
  discard <id>              Stop if needed, delete the worktree and branch, close the task
  pause <id> | --all        Suspend a running agent
  resume <id> | --all       Continue a paused agent

Repository setup (used when a task's worktree is created)
  repo [PATH]               Show the setup for a repository
      --copy FILE           Untracked file to copy into new worktrees (repeatable), e.g. .env
      --clone DIR           Directory to clone copy-on-write (repeatable); path-independent caches only
      --prep CMD            Command to run once in a new worktree, e.g. "npm ci"
      --verify CMD          Command that checks the work, e.g. "npm test" (used from M5)
      --clear               Remove the setup

Task ids can be shortened to any unique prefix.
Data: $TOPSIDE_HOME or ~/Library/Application Support/Topside
Worktrees: $TOPSIDE_WORKTREES or ~/.topside/worktrees
"""

let configuration = EngineConfiguration.standard()
let runnerList: [any AgentRunner] = [ClaudeCodeRunner(), CodexRunner()]
let runnersByKind = Dictionary(uniqueKeysWithValues: runnerList.map { ($0.kind, $0) })

func displayName(_ kind: AgentKind) -> String { runnersByKind[kind]?.displayName ?? kind.rawValue }

func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func store() throws -> TaskStore { try TaskStore(root: configuration.dataDirectory) }

/// Full id from any unique prefix.
func resolveTask(_ prefix: String?) throws -> TopsideTask {
    guard let prefix = prefix?.lowercased(), !prefix.isEmpty else { throw CLIError("Which task? Give its id.") }
    let matches = try store().loadAll().filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
    if matches.count == 1 { return matches[0] }
    throw CLIError(matches.isEmpty ? "No task matches \(prefix)." : "\(prefix) matches \(matches.count) tasks; use more characters.")
}

func requireEngine() throws {
    guard ControlClient.isEngineRunning(socketPath: configuration.socketPath) else {
        throw CLIError("The Topside engine is not running. Start it with `topside serve` in another terminal.")
    }
}

func send(_ request: ControlRequest) async throws -> TopsideTask? {
    try requireEngine()
    let response = try await ControlClient.send(request, socketPath: configuration.socketPath)
    guard response.ok else { throw CLIError(response.error ?? "The engine refused the request.") }
    return response.task
}

func repositoryRoot(_ path: String) async throws -> String {
    let git = try Git.locate()
    let manager = WorkspaceManager(git: git, worktreesRoot: configuration.worktreesRoot, environment: [:])
    return try await manager.repositoryRoot(of: URL(fileURLWithPath: path).standardizedFileURL.path)
}

func chooseAgent(_ name: String?) throws -> AgentKind {
    if let name {
        switch name.lowercased() {
        case "claude", "claude-code", "claudecode": return .claudeCode
        case "codex": return .codex
        default: throw CLIError("Unknown agent \(name). Use claude or codex.")
        }
    }
    for kind in [AgentKind.claudeCode, .codex] where runnersByKind[kind]?.detect() != nil { return kind }
    throw CLIError("Neither Claude Code nor Codex was found. Install one, or check `topside doctor`.")
}

// MARK: Commands

func serve() async throws -> Int32 {
    let engine = try TaskEngine(configuration: configuration, runners: runnerList)
    let stamp = DateFormatter()
    stamp.dateFormat = "HH:mm:ss"
    await engine.setLogger { line in print("\(stamp.string(from: Date()))  \(line)") }
    try configuration.prepareSocketLocation()
    let server = ControlServer(engine: engine, path: configuration.socketPath)
    try server.start()
    await engine.start()
    print("""
        Topside engine running (git \(engine.workspaces.git.version) at \(engine.workspaces.git.executable)).
          data       \(configuration.dataDirectory.path)
          worktrees  \(configuration.worktreesRoot.path)
        Ctrl-C stops the engine; running agents keep going and are picked up on the next start.
        """)
    setvbuf(stdout, nil, _IOLBF, 0)
    let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        signal(sig, SIG_IGN)   // handled below; agents get default dispositions (POSIX_SPAWN_SETSIGDEF)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler {
            server.stop()
            print("\nEngine stopped. Agents that were running are still running.")
            exit(0)
        }
        source.resume()
        return source
    }
    _ = signals
    while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
}

func run(_ args: Arguments) async throws -> Int32 {
    var prompt = args.positional.joined(separator: " ")
    if prompt.isEmpty, isatty(STDIN_FILENO) == 0 {
        prompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLIError("What should the agent do? topside run \"<prompt>\"")
    }
    let repo = try await repositoryRoot(args.value("repo") ?? FileManager.default.currentDirectoryPath)
    let agent = try chooseAgent(args.value("agent"))
    var budget: Double?
    if let b = args.value("budget") {
        guard let v = Double(b), v > 0 else { throw CLIError("--budget needs a positive number of dollars.") }
        budget = v
    }
    let request = TaskRequest(prompt: prompt, repo: repo, agent: agent, mode: args.has("in-place") ? .inPlace : .isolated,
                              model: args.value("model"), budgetUSD: budget)
    guard let task = try await send(ControlRequest(action: .submit, submit: request)) else {
        throw CLIError("The engine did not return the task.")
    }
    print("\(task.shortID)  \(task.title)  [\(displayName(agent)), \(URL(fileURLWithPath: repo).lastPathComponent)]")
    guard args.has("wait") else {
        print("Follow it with `topside logs \(task.shortID) --follow`.")
        return 0
    }
    var lastLine = ""
    while true {
        guard let t = try store().load(task.id) else { break }
        let line = "\(Format.status(t)): \(Format.detail(t))"
        if line != lastLine { print("  \(line)"); lastLine = line }
        if t.status.isSettled {
            print("")
            print(Format.show(t, agentName: displayName(t.agent), takeover: takeover(t)))
            return t.status == .ready ? 0 : 1
        }
        try await Task.sleep(nanoseconds: 300_000_000)
    }
    return 1
}

func takeover(_ t: TopsideTask) -> String? {
    guard let sid = t.steps.flatMap(\.runs).last?.sessionID else { return nil }
    return runnersByKind[t.agent]?.takeoverCommand(sessionID: sid)
}

func list(_ args: Arguments) throws -> Int32 {
    let tasks = try store().loadAll()
        .filter { args.has("all") || $0.status != .closed }
        .sorted { ($0.status.urgency, $1.createdAt) < ($1.status.urgency, $0.createdAt) }
    if tasks.isEmpty {
        print(args.has("all") ? "No tasks yet." : "No open tasks. (`topside list --all` shows closed ones.)")
        return 0
    }
    print([Format.pad("ID", 9), Format.pad("STATUS", 10), Format.pad("AGENT", 7), Format.pad("AGE", 5),
           Format.pad("TITLE", 35), "NOW"].joined())
    for t in tasks { print(Format.listLine(t, agentName: displayName(t.agent))) }
    if !ControlClient.isEngineRunning(socketPath: configuration.socketPath),
       tasks.contains(where: { !$0.status.isSettled }) {
        printErr("\nThe engine is not running, so this may be out of date. Start it with `topside serve`.")
    }
    return 0
}

func logs(_ args: Arguments) async throws -> Int32 {
    var task = try resolveTask(args.positional.first)
    guard let runner = runnersByKind[task.agent] else { throw CLIError("Unknown agent \(task.agent).") }
    var offsets: [String: UInt64] = [:]
    var printedPrep = false
    while true {
        if !printedPrep, let prep = try? String(contentsOf: try store().prepLog(task: task.id), encoding: .utf8) {
            print("── workspace\n" + prep.split(whereSeparator: \.isNewline).map { "  \($0)" }.joined(separator: "\n"))
            printedPrep = true
        }
        for (stepIndex, step) in task.steps.enumerated() {
            for run in step.runs {
                let file = URL(fileURLWithPath: run.directory).appendingPathComponent(ProcessSupervisor.Files.events)
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let start = offsets[file.path] ?? 0
                if start == 0 { print("── step \(stepIndex + 1) (\(task.recipe.steps[stepIndex].label)), run \(run.number)") }
                try handle.seek(toOffset: start)
                let data = handle.readDataToEndOfFile()
                try handle.close()
                guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                let complete = data.prefix(lastNewline + 1)
                for line in complete.split(separator: UInt8(ascii: "\n")) {
                    for e in runner.parse(line: Data(line)) { if let s = Format.event(e) { print("  \(s)") } }
                }
                offsets[file.path] = start + UInt64(complete.count)
            }
        }
        guard args.has("follow"), !task.status.isSettled else { break }
        try await Task.sleep(nanoseconds: 300_000_000)
        guard let reloaded = try store().load(task.id) else { break }
        task = reloaded
    }
    print("── \(Format.status(task)): \(Format.detail(task))")
    return 0
}

func repoCommand(_ args: Arguments) async throws -> Int32 {
    let repo = try await repositoryRoot(args.positional.first ?? FileManager.default.currentDirectoryPath)
    let configs = RepoConfigStore(root: configuration.dataDirectory)
    var setup = configs.setup(for: repo)
    let changing = args.has("clear") || !args.values.isEmpty
    if args.has("clear") { setup = RepoSetup() }
    if !args.all("copy").isEmpty { setup.copyFiles = args.all("copy") }
    if !args.all("clone").isEmpty { setup.cloneDirectories = args.all("clone") }
    if let prep = args.value("prep") { setup.prepCommand = prep.isEmpty ? nil : prep }
    if let verify = args.value("verify") { setup.verifyCommand = verify.isEmpty ? nil : verify }
    if changing { try configs.save(setup, for: repo) }
    print(repo)
    print("  copy files   \(setup.copyFiles.isEmpty ? "-" : setup.copyFiles.joined(separator: ", "))")
    print("  clone dirs   \(setup.cloneDirectories.isEmpty ? "-" : setup.cloneDirectories.joined(separator: ", "))")
    print("  prep         \(setup.prepCommand ?? "-")")
    print("  verify       \(setup.verifyCommand ?? "-")")
    if changing { print("Saved. Applies to tasks dispatched from now on.") }
    return 0
}

func doctor() -> Int32 {
    var ok = true
    do {
        let git = try Git.locate()
        print("✓ git \(git.version)  \(git.executable)")
    } catch {
        print("✗ \(error)")
        ok = false
    }
    var anyAgent = false
    for r in runnerList {
        if let found = r.detect() {
            print("✓ \(r.displayName) \(found.version ?? "")  \(found.executable)")
            anyAgent = true
        } else {
            print("– \(r.displayName) not found")
        }
    }
    if !anyAgent { ok = false }
    let running = ControlClient.isEngineRunning(socketPath: configuration.socketPath)
    print(running ? "✓ engine running" : "– engine not running (start it with `topside serve`)")
    print("  data       \(configuration.dataDirectory.path)")
    print("  worktrees  \(configuration.worktreesRoot.path)")
    return ok ? 0 : 1
}

func simple(_ action: ControlRequest.Action, _ args: Arguments, verb: String) async throws -> Int32 {
    if args.has("all"), action == .pause || action == .resume {
        _ = try await send(ControlRequest(action: action == .pause ? .pauseAll : .resumeAll))
        print(action == .pause ? "Paused all running tasks." : "Resumed all paused tasks.")
        return 0
    }
    let t = try resolveTask(args.positional.first)
    let after = try await send(ControlRequest(action: action, taskID: t.id))
    print("\(t.shortID)  \(verb)" + (after.map { " (\(Format.status($0)))" } ?? ""))
    return 0
}

// MARK: Entry point

func main() async -> Int32 {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first else {
        print(usage)
        return 0
    }
    argv.removeFirst()
    do {
        let args = try Arguments(argv)
        if args.has("help") { print(usage); return 0 }
        switch command {
        case "serve": return try await serve()
        case "run": return try await run(args)
        case "list", "ls": return try list(args)
        case "show":
            let t = try resolveTask(args.positional.first)
            print(Format.show(t, agentName: displayName(t.agent), takeover: takeover(t)))
            return 0
        case "logs": return try await logs(args)
        case "stop": return try await simple(.stop, args, verb: "stopping")
        case "discard": return try await simple(.discard, args, verb: "discarded")
        case "pause": return try await simple(.pause, args, verb: "paused")
        case "resume": return try await simple(.resume, args, verb: "resumed")
        case "repo": return try await repoCommand(args)
        case "doctor": return doctor()
        case "help", "-h", "--help": print(usage); return 0
        default:
            printErr("Unknown command \(command).\n")
            printErr(usage)
            return 2
        }
    } catch {
        printErr("topside: \(error)")
        return 1
    }
}

exit(await main())
