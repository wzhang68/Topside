import Foundation
import Testing
import TopsideCore
@testable import TopsideUIModel

private let claude = AgentKind("a1")
private let codex = AgentKind("a2")

private func repos(_ paths: String...) -> [KnownRepo] {
    paths.enumerated().map { KnownRepo(path: $1, lastUsed: t0.addingTimeInterval(-Double($0))) }
}

@Suite struct LauncherTests {
    @Test func freshDraftUsesRememberedDefaults() {
        let memory = LauncherMemory(repos: repos("/gone", "/src/api"), lastAgent: codex, lastMode: .inPlace)
        let d = LauncherDraft.fresh(memory: memory, agents: [claude, codex], existingRepos: { $0 != "/gone" })
        #expect(d.repo == "/src/api")
        #expect(d.agent == codex)
        #expect(d.mode == .inPlace)
        #expect(d.recipe == .quick)
        // The remembered agent is no longer installed: fall back to the first one that is.
        #expect(LauncherDraft.fresh(memory: memory, agents: [claude]).agent == claude)
        #expect(LauncherDraft.fresh(memory: LauncherMemory(), agents: []).agent == nil)
    }

    @Test func mentionIsOnlyTheTrailingAtWord() {
        var d = LauncherDraft(text: "fix the bug @ap")
        #expect(d.mention == "ap")
        d.text = "@"
        #expect(d.mention == "")
        d.text = "use @Observable here"
        #expect(d.mention == nil)
        d.text = "mail me@example"
        #expect(d.mention == nil)
    }

    @Test func acceptingAMentionSetsTheRepoAndRemovesTheWord() {
        var d = LauncherDraft(text: "fix the bug  @ap")
        d.acceptMention("/src/api")
        #expect(d.repo == "/src/api")
        #expect(d.text == "fix the bug ")
        var e = LauncherDraft(text: "@ap")
        e.acceptMention("/src/api")
        #expect(e.text == "")
    }

    @Test func repoSearchRanksNameMatchesFirst() {
        let all = repos("/src/web-app", "/src/api-server", "/src/apps/legacy", "/work/maps")
        #expect(RepoSearch.search("api", in: all).map(\.path) == ["/src/api-server"])
        // prefix > substring > letters in order > anywhere in the path
        #expect(RepoSearch.search("ap", in: all).map(\.path) == ["/src/api-server", "/src/web-app", "/work/maps", "/src/apps/legacy"])
        #expect(RepoSearch.search("wa", in: all).map(\.path) == ["/src/web-app"])
        #expect(RepoSearch.search("", in: all, limit: 2).map(\.path) == ["/src/web-app", "/src/api-server"])
        #expect(RepoSearch.search("zzz", in: all).isEmpty)
    }

    @Test func tabAndArrowsChangeOptions() {
        var d = LauncherDraft(repo: "/a", agent: claude)
        d.moveFocus(forward: false)
        #expect(d.focus == .mode)
        d.cycle(forward: true, repos: [], agents: [], recipes: [])
        #expect(d.mode == .inPlace)
        d.moveFocus(forward: true)
        d.moveFocus(forward: true)
        d.moveFocus(forward: true)
        #expect(d.focus == .agent)
        d.cycle(forward: true, repos: [], agents: [claude, codex], recipes: [])
        #expect(d.agent == codex)
        d.cycle(forward: true, repos: [], agents: [claude, codex], recipes: [])
        #expect(d.agent == claude)
        d.moveFocus(forward: false)
        d.cycle(forward: false, repos: repos("/a", "/b", "/c"), agents: [], recipes: [])
        #expect(d.repo == "/c")
    }

    @Test func suggestionSelectionWraps() {
        var d = LauncherDraft()
        d.moveSuggestion(by: -1, count: 3)
        #expect(d.suggestionIndex == 2)
        d.moveSuggestion(by: 1, count: 3)
        #expect(d.suggestionIndex == 0)
    }

    @Test func requestNeedsPromptRepoAndAgent() {
        var d = LauncherDraft(text: "  ")
        #expect(d.problem != nil)
        d.text = "add rate limiting\n"
        #expect(d.problem?.contains("仓库") == true)
        d.repo = "/src/api"
        #expect(d.problem?.contains("agent") == true)
        d.agent = codex
        d.mode = .inPlace
        let r = d.request()
        #expect(r?.prompt == "add rate limiting")
        #expect(r?.repo == "/src/api")
        #expect(r?.agent == codex)
        #expect(r?.mode == .inPlace)
    }

    @Test func memoryKeepsRecentReposFirst() throws {
        var m = LauncherMemory()
        m.recordDispatch(repo: "/a", agent: claude, mode: .isolated, now: t0)
        m.recordDispatch(repo: "/b", agent: codex, mode: .inPlace, now: t0.addingTimeInterval(1))
        m.touch(repo: "/a", now: t0.addingTimeInterval(2))
        m.learn(repo: "/c", usedAt: t0.addingTimeInterval(-10))
        m.learn(repo: "/b", usedAt: t0.addingTimeInterval(100))   // already known: not moved
        #expect(m.repos.map(\.path) == ["/a", "/b", "/c"])
        #expect(m.lastAgent == codex)
        #expect(m.lastMode == .inPlace)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("topside-ui-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LauncherMemoryStore(dataDirectory: dir)
        #expect(store.load() == LauncherMemory())
        try store.save(m)
        #expect(store.load() == m)
    }

    @Test func memoryIsCapped() {
        var m = LauncherMemory()
        for i in 0..<(LauncherMemory.maxRepos + 5) { m.touch(repo: "/r\(i)", now: t0.addingTimeInterval(Double(i))) }
        #expect(m.repos.count == LauncherMemory.maxRepos)
        #expect(m.repos.first?.path == "/r\(LauncherMemory.maxRepos + 4)")
    }
}
