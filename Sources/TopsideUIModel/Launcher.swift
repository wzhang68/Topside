import Foundation
import TopsideCore
import TopsideEngine

/// A repository the launcher knows about: used before, or added by dropping a folder.
public struct KnownRepo: Codable, Sendable, Equatable {
    public var path: String
    public var lastUsed: Date

    public init(path: String, lastUsed: Date) {
        self.path = path
        self.lastUsed = lastUsed
    }
}

/// What the launcher remembers between uses (design doc 6.1: defaults are "the last one used").
public struct LauncherMemory: Codable, Sendable, Equatable {
    /// Most recently used first.
    public var repos: [KnownRepo]
    public var lastAgent: AgentKind?
    public var lastMode: WorkspaceMode

    public static let maxRepos = 50

    public init(repos: [KnownRepo] = [], lastAgent: AgentKind? = nil, lastMode: WorkspaceMode = .isolated) {
        self.repos = repos
        self.lastAgent = lastAgent
        self.lastMode = lastMode
    }

    /// Put `repo` first (adding it if new).
    public mutating func touch(repo: String, now: Date) {
        repos.removeAll { $0.path == repo }
        repos.insert(KnownRepo(path: repo, lastUsed: now), at: 0)
        if repos.count > Self.maxRepos { repos.removeLast(repos.count - Self.maxRepos) }
    }

    public mutating func recordDispatch(repo: String, agent: AgentKind, mode: WorkspaceMode, now: Date) {
        touch(repo: repo, now: now)
        lastAgent = agent
        lastMode = mode
    }

    /// Add repositories seen elsewhere (e.g. tasks dispatched from the command line)
    /// without moving the ones already known.
    public mutating func learn(repo: String, usedAt: Date) {
        guard !repos.contains(where: { $0.path == repo }) else { return }
        repos.append(KnownRepo(path: repo, lastUsed: usedAt))
        repos.sort { $0.lastUsed > $1.lastUsed }
        if repos.count > Self.maxRepos { repos.removeLast(repos.count - Self.maxRepos) }
    }

    public mutating func forget(repo: String) {
        repos.removeAll { $0.path == repo }
    }
}

/// `launcher.json` in the data directory. Unreadable means empty, never fatal.
public struct LauncherMemoryStore: Sendable {
    public let file: URL

    public init(dataDirectory: URL) {
        file = dataDirectory.appendingPathComponent("launcher.json")
    }

    public func load() -> LauncherMemory {
        guard let data = try? Data(contentsOf: file) else { return LauncherMemory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LauncherMemory.self, from: data)) ?? LauncherMemory()
    }

    public func save(_ memory: LauncherMemory) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(memory).write(to: file, options: .atomic)
    }
}

/// Fuzzy search over known repositories for `@` in the launcher.
public enum RepoSearch {
    /// Best matches first; an empty query lists repositories by recency.
    public static func search(_ query: String, in repos: [KnownRepo], limit: Int = 6) -> [KnownRepo] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(repos.prefix(limit)) }
        let scored = repos.enumerated().compactMap { index, repo -> (Int, Int, KnownRepo)? in
            score(q, path: repo.path).map { ($0, index, repo) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.prefix(limit).map(\.2)
    }

    /// Higher is better; nil means no match. Folder name beats full path;
    /// prefix beats substring beats letters in order.
    static func score(_ q: String, path: String) -> Int? {
        let name = RepoNames.base(path).lowercased()
        let full = path.lowercased()
        if name == q { return 100 }
        if name.hasPrefix(q) { return 80 }
        if name.contains(q) { return 60 }
        if isSubsequence(q, of: name) { return 40 }
        if full.contains(q) { return 20 }
        return nil
    }

    static func isSubsequence(_ q: String, of s: String) -> Bool {
        var it = s.makeIterator()
        for c in q {
            var found = false
            while let x = it.next() { if x == c { found = true; break } }
            if !found { return false }
        }
        return true
    }
}

/// The launcher's option row (design doc 6.1). ⇥ moves between them.
public enum LauncherField: Int, CaseIterable, Sendable {
    case prompt, repo, agent, recipe, mode
}

/// A dispatch being written. Pure state; the app owns one and turns it into a `TaskRequest`.
public struct LauncherDraft: Sendable, Equatable {
    public var text: String
    public var repo: String?
    public var agent: AgentKind?
    public var recipe: Recipe
    public var mode: WorkspaceMode
    public var focus: LauncherField
    /// Highlighted row in the `@` suggestions.
    public var suggestionIndex: Int

    public init(text: String = "", repo: String? = nil, agent: AgentKind? = nil, recipe: Recipe = .quick,
                mode: WorkspaceMode = .isolated) {
        self.text = text
        self.repo = repo
        self.agent = agent
        self.recipe = recipe
        self.mode = mode
        self.focus = .prompt
        self.suggestionIndex = 0
    }

    /// A fresh draft with the remembered defaults. `agents` are the installed ones, in preference order.
    public static func fresh(memory: LauncherMemory, agents: [AgentKind], existingRepos: (String) -> Bool = { _ in true }) -> LauncherDraft {
        let repo = memory.repos.first(where: { existingRepos($0.path) })?.path
        let agent = memory.lastAgent.flatMap { agents.contains($0) ? $0 : nil } ?? agents.first
        return LauncherDraft(repo: repo, agent: agent, mode: memory.lastMode)
    }

    /// The `@word` being typed at the end of the text, if any. Only the end counts:
    /// "@" elsewhere in a prompt (e.g. "@Observable") is left alone.
    public var mention: String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let word = text[text.index(after: at)...]
        if word.contains(where: \.isWhitespace) { return nil }
        return String(word)
    }

    /// Choose a repository from the suggestions: it replaces the `@word`.
    public mutating func acceptMention(_ repo: String) {
        if mention != nil, let at = text.lastIndex(of: "@") {
            text = String(text[..<at])
            while text.last == " " { text.removeLast() }
            if !text.isEmpty { text += " " }
        }
        self.repo = repo
        suggestionIndex = 0
    }

    public mutating func moveSuggestion(by delta: Int, count: Int) {
        guard count > 0 else { suggestionIndex = 0; return }
        suggestionIndex = ((suggestionIndex + delta) % count + count) % count
    }

    /// ⇥ / ⇧⇥.
    public mutating func moveFocus(forward: Bool) {
        let all = LauncherField.allCases
        let i = all.firstIndex(of: focus)!
        focus = all[(i + (forward ? 1 : all.count - 1)) % all.count]
    }

    /// ← / → on a focused option: step through its values.
    public mutating func cycle(forward: Bool, repos: [KnownRepo], agents: [AgentKind], recipes: [Recipe]) {
        func step<T: Equatable>(_ values: [T], _ current: T?) -> T? {
            guard !values.isEmpty else { return current }
            guard let current, let i = values.firstIndex(of: current) else { return values.first }
            return values[(i + (forward ? 1 : values.count - 1)) % values.count]
        }
        switch focus {
        case .prompt: break
        case .repo: repo = step(repos.map(\.path), repo)
        case .agent: agent = step(agents, agent)
        case .recipe: recipe = step(recipes, recipe) ?? recipe
        case .mode: mode = mode == .isolated ? .inPlace : .isolated
        }
    }

    public var prompt: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why it cannot be dispatched yet, or nil when it can.
    public var problem: String? {
        if prompt.isEmpty { return "写一句需求" }
        if repo == nil { return "选一个仓库：输入 @ 搜索，或把文件夹拖进来" }
        if agent == nil { return "没有找到可用的 agent" }
        return nil
    }

    public func request() -> TaskRequest? {
        guard problem == nil, let repo, let agent else { return nil }
        // The engine runs only the quick recipe until M5, so the choice is not sent yet.
        return TaskRequest(prompt: prompt, repo: repo, agent: agent, mode: mode)
    }
}
