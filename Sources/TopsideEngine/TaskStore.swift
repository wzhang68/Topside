import Foundation
import TopsideCore

/// Where an engine keeps its state. Defaults follow design doc 7.5 and 8.2;
/// TOPSIDE_HOME and TOPSIDE_WORKTREES override them (tests, development).
public struct EngineConfiguration: Sendable {
    public var dataDirectory: URL
    public var worktreesRoot: URL
    /// nil = no limit (decision D5). Optional cap for people who want one.
    public var maxConcurrent: Int?
    /// Base environment for agents and prep commands.
    public var environment: [String: String]
    /// Seconds between SIGINT → SIGTERM → SIGKILL when stopping a run.
    public var stopGracePeriod: Double

    public init(dataDirectory: URL, worktreesRoot: URL, maxConcurrent: Int? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment, stopGracePeriod: Double = 5) {
        self.dataDirectory = dataDirectory
        self.worktreesRoot = worktreesRoot
        self.maxConcurrent = maxConcurrent
        self.environment = environment
        self.stopGracePeriod = stopGracePeriod
    }

    public static func standard(environment env: [String: String] = ProcessInfo.processInfo.environment) -> EngineConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let data = env["TOPSIDE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Library/Application Support/Topside")
        let worktrees = env["TOPSIDE_WORKTREES"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".topside/worktrees")
        return EngineConfiguration(dataDirectory: data, worktreesRoot: worktrees, environment: env)
    }

    /// `<data>/engine.sock`, unless that is longer than a Unix socket path may
    /// be (103 bytes), in which case a short path in a private per-user
    /// directory under /tmp, derived from the data directory.
    public var socketPath: String {
        let preferred = dataDirectory.appendingPathComponent("engine.sock").path
        if preferred.utf8.count <= 100 { return preferred }
        return "\(Self.shortSocketDirectory)/\(Self.fnv1a(dataDirectory.standardizedFileURL.path)).sock"
    }

    static var shortSocketDirectory: String { "/tmp/topside-\(getuid())" }

    /// Create the socket's directory. A fallback directory in /tmp must be
    /// ours and private: anyone can create files in /tmp, and a socket planted
    /// there by another user would receive our requests (including prompts).
    public func prepareSocketLocation() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard dir == Self.shortSocketDirectory else { return }
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(),
              (st.st_mode & 0o077) == 0 else {
            throw EngineError("\(dir) is not a private directory owned by you; refusing to put the engine socket there.")
        }
    }

    /// Stable across processes (Swift's Hasher is seeded per process).
    static func fnv1a(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }
}

/// One directory per task: task.json (atomic writes) plus one directory per run.
public struct TaskStore: Sendable {
    public let root: URL
    public var tasksDirectory: URL { root.appendingPathComponent("tasks") }

    public init(root: URL) throws {
        self.root = root
        let fm = FileManager.default
        for dir in [root, root.appendingPathComponent("tasks")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)   // prompts and code live here
        }
    }

    /// Compact: task.json is rewritten often. `topside show` is the readable view.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public func directory(of id: TaskID) -> URL {
        tasksDirectory.appendingPathComponent(id.uuidString.lowercased())
    }

    public func save(_ task: TopsideTask) throws {
        let dir = directory(of: task.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(task)
        try data.write(to: dir.appendingPathComponent("task.json"), options: .atomic)
    }

    public func load(_ id: TaskID) -> TopsideTask? {
        let url = directory(of: id).appendingPathComponent("task.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TopsideTask.self, from: data)
    }

    /// All tasks that can be read. Unreadable ones are skipped, not fatal.
    public func loadAll() -> [TopsideTask] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tasksDirectory.path)) ?? []
        return names.compactMap { UUID(uuidString: $0) }.compactMap(load)
    }

    public func runDirectory(task: TaskID, step: Int, run: Int) -> URL {
        directory(of: task).appendingPathComponent("runs/\(step)-\(run)")
    }

    public func prepLog(task: TaskID) -> URL {
        directory(of: task).appendingPathComponent("prep.log")
    }
}

/// Per-repository setup (design doc 8.2), stored in repos.json keyed by the repo's path.
public struct RepoConfigStore: Sendable {
    public let file: URL

    public init(root: URL) {
        file = root.appendingPathComponent("repos.json")
    }

    public func all() -> [String: RepoSetup] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: RepoSetup].self, from: data)) ?? [:]
    }

    public func setup(for repo: String) -> RepoSetup {
        all()[repo] ?? RepoSetup()
    }

    public func save(_ setup: RepoSetup, for repo: String) throws {
        var everything = all()
        everything[repo] = setup
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TaskStore.encoder.encode(everything).write(to: file, options: .atomic)
    }
}
