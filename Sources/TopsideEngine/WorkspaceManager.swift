import Foundation
import TopsideCore

public struct WorkspaceError: Error, CustomStringConvertible {
    public var message: String
    public var detail: String?
    public var description: String { message }
}

/// Runs operations on the same key one after another, in submission order.
actor SerialQueues {
    private var tails: [String: Task<Void, Never>] = [:]

    func run<T: Sendable>(_ key: String, _ body: @Sendable @escaping () async throws -> T) async throws -> T {
        let previous = tails[key]
        let task = Task<T, Error> {
            await previous?.value
            return try await body()
        }
        tails[key] = Task { _ = try? await task.value }
        return try await task.value
    }
}

/// Isolated worktrees (design doc 8.2), implemented after the M0 spike
/// Spikes/m0-worktree/worktree_flow.py.
public struct WorkspaceManager: Sendable {
    public let git: Git
    public let worktreesRoot: URL
    let environment: [String: String]
    /// `git worktree add/remove` on one repository must not run concurrently:
    /// a second git can read the first one's half-written .git/worktrees/<name>
    /// and fail ("failed to read .../commondir"). Found by the 50-task test in M1.
    let repoQueues = SerialQueues()

    public init(git: Git, worktreesRoot: URL, environment: [String: String]) {
        self.git = git
        self.worktreesRoot = worktreesRoot.standardizedFileURL
        self.environment = environment
    }

    public static let branchPrefix = "topside/"

    /// The repository's top-level directory, or an error if `path` is not in a git repository.
    public func repositoryRoot(of path: String) async throws -> String {
        do {
            return try await git.trimmed(["rev-parse", "--show-toplevel"], in: path)
        } catch {
            throw WorkspaceError(message: "\(path) is not inside a git repository.")
        }
    }

    public func prepare(_ task: TopsideTask, log: URL) async throws -> WorkspaceInfo {
        let repo = task.repo
        let base: String
        var unborn = false
        if let head = try? await git.trimmed(["rev-parse", "--verify", "HEAD^{commit}"], in: repo) {
            base = head
        } else {
            // Straight after `git init` there is no commit to branch from. Start
            // from the empty tree: changes are then measured against nothing.
            guard (try? await git.trimmed(["rev-parse", "--git-dir"], in: repo)) != nil else {
                throw WorkspaceError(message: "\(repo) is not inside a git repository.")
            }
            base = try await git.trimmed(["hash-object", "-t", "tree", "/dev/null"], in: repo)
            unborn = true
        }

        if task.mode == .inPlace {
            return WorkspaceInfo(path: repo, branch: nil, baseCommit: base)
        }

        let slug = Self.slug(task.title) + "-" + task.shortID
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        let path = worktreesRoot.appendingPathComponent(repoName).appendingPathComponent(slug).path
        let branch = Self.branchPrefix + slug
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        if unborn && !git.supportsOrphanWorktrees {
            throw WorkspaceError(message: "The repository has no commits yet. Make a first commit, or use git 2.42 or newer "
                                 + "(found \(git.version)), or run the task in place.")
        }
        // An empty repository gets an orphan branch: it starts with no files and no history.
        let add = unborn ? ["worktree", "add", "--quiet", "--orphan", "-b", branch, path]
                         : ["worktree", "add", "--quiet", "-b", branch, path, base]
        do {
            let git = self.git
            _ = try await repoQueues.run(repo) {
                try await git.run(add, in: repo)
            }
        } catch let e as GitError {
            throw WorkspaceError(message: "Could not create the worktree.", detail: e.detail)
        }
        var notes: [String] = ["worktree \(path) on \(branch) from \(base)"]

        for rel in task.setup.copyFiles {
            guard let src = Self.inside(repo, rel), let dst = Self.inside(path, rel) else {
                notes.append("skipped \(rel): path leaves the repository")
                continue
            }
            guard FileManager.default.fileExists(atPath: src) else {
                notes.append("skipped \(rel): not present in the main checkout")
                continue
            }
            if FileManager.default.fileExists(atPath: dst) { continue }
            try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            do {
                try FileManager.default.copyItem(atPath: src, toPath: dst)
                notes.append("copied \(rel)")
            } catch {
                notes.append("could not copy \(rel): \(error.localizedDescription)")
            }
        }

        for rel in task.setup.cloneDirectories {
            guard let src = Self.inside(repo, rel), let dst = Self.inside(path, rel),
                  FileManager.default.fileExists(atPath: src), !FileManager.default.fileExists(atPath: dst) else { continue }
            // APFS copy-on-write clone: instant and nearly free. Only safe for path-independent caches (M0).
            let r = try await Command.run("/bin/cp", ["-c", "-R", src, dst])
            notes.append(r.exitCode == 0 ? "cloned \(rel)" : "could not clone \(rel): \(r.tail(3))")
        }

        var logText = notes.joined(separator: "\n") + "\n"
        defer { try? logText.write(to: log, atomically: true, encoding: .utf8) }
        if let prep = task.setup.prepCommand, !prep.trimmingCharacters(in: .whitespaces).isEmpty {
            let r = try await Command.shell(prep, in: path, environment: environment)
            logText += "\n$ \(prep)\n\(r.stdout)\(r.stderr)\nexit \(r.exitCode)\n"
            guard r.exitCode == 0 else {
                throw WorkspaceError(message: "The prep command failed (exit \(r.exitCode)): \(prep)", detail: r.tail())
            }
        }
        return WorkspaceInfo(path: path, branch: branch, baseCommit: base)
    }

    /// Committed, staged, unstaged and untracked changes against the base
    /// commit, computed with a throwaway index so the workspace's real index
    /// is never touched. Respects .gitignore.
    public func changeSet(_ info: WorkspaceInfo) async throws -> [FileChange] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("topside-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let env = ["GIT_INDEX_FILE": tmp.path]
        // No commit yet (a repository straight after `git init`): start from an empty index.
        if (try? await git.run(["read-tree", "HEAD"], in: info.path, extraEnvironment: env)) == nil {
            try await git.run(["read-tree", "--empty"], in: info.path, extraEnvironment: env)
        }
        try await git.run(["add", "-A"], in: info.path, extraEnvironment: env)
        let out = try await git.run(["diff", "--cached", "--numstat", "--no-renames", "-z", info.baseCommit],
                                    in: info.path, extraEnvironment: env)
        return Self.parseNumstatZ(out)
    }

    /// `git diff --numstat -z`: "added\tdeleted\tpath\0" per file; "-" for binary.
    static func parseNumstatZ(_ out: String) -> [FileChange] {
        out.split(separator: "\0").compactMap { entry in
            let parts = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return FileChange(path: String(parts[2]), added: Int(parts[0]), deleted: Int(parts[1]))
        }
    }

    /// Remove a worktree and its branch. Refuses anything Topside did not create.
    public func remove(_ info: WorkspaceInfo, repo: String) async throws {
        guard let branch = info.branch else { return }   // in-place: nothing to remove
        let path = URL(fileURLWithPath: info.path).standardizedFileURL.path
        guard branch.hasPrefix(Self.branchPrefix), path.hasPrefix(worktreesRoot.path + "/") else {
            throw WorkspaceError(message: "Refusing to remove \(path): not a Topside worktree.")
        }
        let git = self.git
        try await repoQueues.run(repo) {
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try await git.run(["worktree", "remove", "--force", path], in: repo)
                } catch {
                    // Not registered any more (or repo moved): delete the directory, then prune.
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            _ = try? await git.run(["worktree", "prune"], in: repo)
            let exists = (try? await git.trimmed(["branch", "--list", branch], in: repo)).map { !$0.isEmpty } ?? false
            if exists { try await git.run(["branch", "-D", branch], in: repo) }
        }
    }

    static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        var out = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash && !out.isEmpty {
                out.append("-")
                lastDash = true
            }
            if out.count >= 32 { break }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "task" : trimmed
    }

    /// `base/rel` if it stays inside `base`, else nil.
    static func inside(_ base: String, _ rel: String) -> String? {
        let b = URL(fileURLWithPath: base).standardizedFileURL.path
        let full = URL(fileURLWithPath: base).appendingPathComponent(rel).standardizedFileURL.path
        return full.hasPrefix(b + "/") ? full : nil
    }
}
