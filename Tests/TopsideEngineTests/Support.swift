import Darwin
import Foundation
import TopsideCore
import TopsideEngine
import TopsideRunners

enum Paths {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fakeAgent = repoRoot.appendingPathComponent("scripts/fake-agent.sh").path
    static func fixture(_ rel: String) -> String { repoRoot.appendingPathComponent("Tests/Fixtures/\(rel)").path }
    static let claudeAllow = fixture("claude-code/2.1.325/allow/events.jsonl")
    static let claudeBudget = fixture("claude-code/2.1.325/budget/events.jsonl")
    static let codexResume = fixture("codex/0.169.0/resume/events.jsonl")
}

struct TestError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

@discardableResult
func sh(_ command: String, in dir: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", command]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/usr/bin:/bin:" + (env["PATH"] ?? "")   // the new git first
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard p.terminationStatus == 0 else { throw TestError("`\(command)` failed: \(text)") }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A temporary sandbox: a git repo with one commit, a data directory and a worktree root.
struct Sandbox {
    let root: URL
    let repo: String
    let data: URL
    let worktrees: URL

    /// `commits: false`: a repository straight after `git init`, with no commit yet.
    init(commits: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("topside-tests-\(UUID().uuidString.prefix(8))")
        let repoURL = root.appendingPathComponent("my-repo")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        repo = repoURL.standardizedFileURL.path
        data = root.appendingPathComponent("data")
        worktrees = root.appendingPathComponent("worktrees")
        try sh(commits ? """
            git init -q && printf 'hello\\n' > README.md && printf '.env\\n' > .gitignore && \
            git add . && git -c user.name=t -c user.email=t@localhost commit -qm init
            """ : "git init -q", in: repo)
    }

    func engine(_ fake: [String: String] = [:], maxConcurrent: Int? = nil) throws -> TaskEngine {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in fake { env[k] = v }
        let config = EngineConfiguration(dataDirectory: data, worktreesRoot: worktrees, maxConcurrent: maxConcurrent,
                                         environment: env, stopGracePeriod: 1)
        return try TaskEngine(configuration: config, runners: [
            ClaudeCodeRunner(executableOverride: Paths.fakeAgent),
            CodexRunner(executableOverride: Paths.fakeAgent),
        ])
    }

    /// What a task must never change in the user's own checkout: its HEAD,
    /// working-tree status and non-Topside branches. (topside/ branches are
    /// shared with worktrees by design, so they are excluded.)
    func mainCheckout() throws -> String {
        try sh("git rev-parse HEAD && git status --porcelain && git branch --list | grep -v ' topside/' || true",
               in: repo)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

func parentPID(of pid: Int32) -> Int32? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// Poll until `condition` holds for the task, or fail after `timeout` seconds.
@discardableResult
/// Timeouts are generous on purpose: they only matter when something is wrong, and
/// CI machines (or a busy laptop) can be several times slower than a quiet one.
func waitFor(_ engine: TaskEngine, _ id: TaskID, timeout: Double = 60, _ what: String = "condition",
             _ condition: @escaping @Sendable (TopsideTask) -> Bool) async throws -> TopsideTask {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let t = await engine.task(id), condition(t) { return t }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let t = await engine.task(id)
    throw TestError("Timed out waiting for \(what); task is \(String(describing: t?.status)) \(t?.failure?.message ?? "")")
}

func settled(_ engine: TaskEngine, _ id: TaskID, timeout: Double = 60) async throws -> TopsideTask {
    try await waitFor(engine, id, timeout: timeout, "settled") { $0.status.isSettled }
}

func running(_ engine: TaskEngine, _ id: TaskID) async throws -> TopsideTask {
    try await waitFor(engine, id, "running agent") { $0.currentRun?.pid != nil && $0.currentRun?.isFinished == false }
}
