import Foundation
import Testing
import TopsideCore
@testable import TopsideEngine

@Suite struct WorkspaceTests {
    @Test func gitLocatorSkipsTooOldVersions() throws {
        let git = try Git.locate()
        let parts = git.version.split(separator: ".").compactMap { Int($0) }
        #expect(!parts.lexicographicallyPrecedes(Git.minimumVersion))
    }

    @Test func changeSetCountsCommittedUncommittedAndUntracked() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let git = try Git.locate()
        let manager = WorkspaceManager(git: git, worktreesRoot: box.worktrees, environment: ProcessInfo.processInfo.environment)
        let base = try sh("git rev-parse HEAD", in: box.repo)
        try sh("""
            printf 'a\\nb\\n' > committed.txt && git add committed.txt && \
            git -c user.name=t -c user.email=t@localhost commit -qm c && \
            printf 'changed\\n' >> README.md && printf 'x\\ny\\nz\\n' > untracked.txt && \
            printf 'secret\\n' > .env && printf 'name with space\\n' > 'sp ace.txt'
            """, in: box.repo)
        let files = try await manager.changeSet(WorkspaceInfo(path: box.repo, branch: nil, baseCommit: base))
        #expect(files == [
            FileChange(path: "README.md", added: 1, deleted: 0),
            FileChange(path: "committed.txt", added: 2, deleted: 0),
            FileChange(path: "sp ace.txt", added: 1, deleted: 0),
            FileChange(path: "untracked.txt", added: 3, deleted: 0),
        ])
        // The real index was not touched: untracked.txt is still untracked.
        #expect(try sh("git status --porcelain untracked.txt", in: box.repo) == "?? untracked.txt")
    }

    @Test func refusesToRemoveAnythingItDidNotCreate() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let manager = WorkspaceManager(git: try Git.locate(), worktreesRoot: box.worktrees,
                                       environment: ProcessInfo.processInfo.environment)
        await #expect(throws: WorkspaceError.self) {
            try await manager.remove(WorkspaceInfo(path: box.repo, branch: "main", baseCommit: "x"), repo: box.repo)
        }
        await #expect(throws: WorkspaceError.self) {
            try await manager.remove(WorkspaceInfo(path: box.worktrees.path + "/../my-repo", branch: "topside/x",
                                                   baseCommit: "x"), repo: box.repo)
        }
        #expect(FileManager.default.fileExists(atPath: box.repo + "/README.md"))
    }

    @Test func socketPathStaysShortAndPrivate() throws {
        let short = EngineConfiguration(dataDirectory: URL(fileURLWithPath: "/tmp/x"), worktreesRoot: URL(fileURLWithPath: "/tmp/w"))
        #expect(short.socketPath == "/tmp/x/engine.sock")
        let deep = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 120))
        let long = EngineConfiguration(dataDirectory: deep, worktreesRoot: deep)
        #expect(long.socketPath.hasPrefix("/tmp/topside-\(getuid())/"))
        #expect(long.socketPath.utf8.count < 104)
        #expect(long.socketPath == EngineConfiguration(dataDirectory: deep, worktreesRoot: deep).socketPath)   // stable
        try long.prepareSocketLocation()
        let attrs = try FileManager.default.attributesOfItem(atPath: (long.socketPath as NSString).deletingLastPathComponent)
        #expect(attrs[.posixPermissions] as? Int == 0o700)
    }

    @Test func slugsAndPathContainment() {
        #expect(WorkspaceManager.slug("Add rate-limiting to API!!") == "add-rate-limiting-to-api")
        #expect(WorkspaceManager.slug("给 api 加限流") == "api")
        #expect(WorkspaceManager.slug("限流") == "task")
        #expect(WorkspaceManager.inside("/a/b", "c/d.txt") == "/a/b/c/d.txt")
        #expect(WorkspaceManager.inside("/a/b", "../c") == nil)
        #expect(WorkspaceManager.inside("/a/b", "/etc/passwd") == "/a/b/etc/passwd")
        #expect(WorkspaceManager.parseNumstatZ("1\t2\ta.txt\0-\t-\tbin.png\0") == [
            FileChange(path: "a.txt", added: 1, deleted: 2), FileChange(path: "bin.png", added: nil, deleted: nil),
        ])
    }
}
