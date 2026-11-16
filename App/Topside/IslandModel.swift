import AppKit
import Observation
import TopsideCore
import TopsideEngine
import TopsideUIModel

/// What the window does on the model's behalf (implemented by IslandController).
@MainActor
protocol IslandWindow: AnyObject {
    func expand(pinned: Bool)
    func collapse()
    func openLauncher()
    func closeLauncher(clear: Bool)
}

/// Everything the island's views read and do. Window mechanics (hover,
/// focus, hot keys) live in IslandController.
@MainActor @Observable
final class IslandModel {
    enum Mode: Equatable { case collapsed, expanded, launcher }

    var mode: Mode = .collapsed
    var geometry: NotchGeometry
    /// The island's current size, as laid out by SwiftUI. Used for hit-testing.
    var islandSize: CGSize = .zero

    // Launcher
    var draft = LauncherDraft()
    var launcherMessage: String?
    var submitting = false
    /// Bumped to put the cursor in the prompt field.
    var focusRequest = 0
    private(set) var memory: LauncherMemory

    // List
    var activityShown: TaskID?
    var confirmingDiscard: TaskID?
    var collapsedGroups: Set<String> = []
    /// A short-lived line in the list's footer (e.g. "已复制分支名").
    var notice: String?

    let host: EngineHost
    let store: IslandStore
    @ObservationIgnored weak var window: IslandWindow?
    @ObservationIgnored private let memoryStore: LauncherMemoryStore
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(host: EngineHost, store: IslandStore) {
        self.host = host
        self.store = store
        memoryStore = LauncherMemoryStore(dataDirectory: host.dataDirectory)
        memory = memoryStore.load()
        geometry = NotchGeometry(ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                               visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)))
    }

    // MARK: Collapsed island

    /// With nothing to show, the island shrinks to the notch itself (invisible
    /// against it), or to a small pill on screens without one.
    var collapsedSize: CGSize {
        if store.counts.isEmpty {
            return CGSize(width: geometry.hasNotch ? geometry.notchWidth : NotchGeometry.virtualNotchWidth,
                          height: geometry.topBarHeight)
        }
        return geometry.collapsedSize
    }

    // MARK: Launcher

    var agents: [AgentKind] { host.installedAgents }

    var knownRepos: [KnownRepo] {
        memory.repos.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var suggestions: [KnownRepo] {
        guard let query = draft.mention else { return [] }
        return RepoSearch.search(query, in: knownRepos)
    }

    func prepareDraft() {
        learnReposFromTasks()
        // Keep an unsent prompt (closed by clicking elsewhere); refresh the options.
        if draft.prompt.isEmpty {
            draft = freshDraft()
        } else {
            fillMissingOptions()
            draft.focus = .prompt
        }
        launcherMessage = nil
    }

    /// Once the engine is up, fill in what was not known when the launcher opened.
    func engineStarted() {
        learnReposFromTasks()
        guard mode == .launcher else { return }
        fillMissingOptions()
        if launcherMessage == host.statusText { launcherMessage = nil }
    }

    private func freshDraft() -> LauncherDraft {
        LauncherDraft.fresh(memory: memory, agents: agents, existingRepos: { FileManager.default.fileExists(atPath: $0) })
    }

    private func fillMissingOptions() {
        let fresh = freshDraft()
        if draft.repo == nil { draft.repo = fresh.repo }
        if draft.agent == nil { draft.agent = fresh.agent }
    }

    func acceptSuggestion() {
        let list = suggestions
        guard !list.isEmpty else { return }
        draft.acceptMention(list[min(draft.suggestionIndex, list.count - 1)].path)
        focusRequest += 1
    }

    /// ↩ (or ⌘↩ with `keepOpen`).
    func submit(keepOpen: Bool) {
        if !suggestions.isEmpty { acceptSuggestion(); return }
        guard !submitting else { return }
        guard let request = draft.request() else {
            launcherMessage = draft.problem
            return
        }
        guard let engine = host.engine else {
            launcherMessage = host.statusText
            return
        }
        submitting = true
        Task {
            defer { submitting = false }
            do {
                let task = try await engine.submit(request)
                memory.recordDispatch(repo: request.repo, agent: request.agent, mode: request.mode, now: Date())
                try? memoryStore.save(memory)
                draft.text = ""
                if keepOpen {
                    launcherMessage = "已派出：\(task.title)"
                    focusRequest += 1
                } else {
                    window?.closeLauncher(clear: true)
                }
            } catch {
                launcherMessage = "\(error)"
            }
        }
    }

    /// A folder dropped on the island or chosen with "添加文件夹…": its repository becomes the choice.
    func addRepository(folder: URL) {
        guard let engine = host.engine else {
            launcherMessage = host.statusText
            return
        }
        Task {
            do {
                let root = try await engine.workspaces.repositoryRoot(of: folder.standardizedFileURL.path)
                memory.touch(repo: root, now: Date())
                try? memoryStore.save(memory)
                if mode != .launcher { window?.openLauncher() }
                draft.repo = root
                launcherMessage = nil
            } catch {
                if mode != .launcher { window?.openLauncher() }
                launcherMessage = "\(folder.lastPathComponent) 不在 git 仓库里"
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加"
        panel.message = "选择一个 git 仓库"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { addRepository(folder: url) }
        window?.openLauncher()
    }

    /// Repositories of tasks dispatched elsewhere (e.g. `topside run`) become choices too.
    func learnReposFromTasks() {
        let before = memory
        for t in store.tasks.values { memory.learn(repo: t.repo, usedAt: t.createdAt) }
        if memory != before { try? memoryStore.save(memory) }
    }

    // MARK: Task actions (the ⋯ menu, design doc 6.6)

    func toggleActivity(_ t: TopsideTask) {
        activityShown = activityShown == t.id ? nil : t.id
    }

    func activity(_ t: TopsideTask) -> [String] {
        guard let runner = host.runner(t.agent) else { return [] }
        return Activity.recent(t, runner: runner)
    }

    func setPaused(_ t: TopsideTask, _ paused: Bool) {
        perform { try await $0.setPaused(t.id, paused) }
    }

    func stop(_ t: TopsideTask) {
        perform { try await $0.stop(t.id) }
    }

    func discard(_ t: TopsideTask) {
        confirmingDiscard = nil
        perform { try await $0.discard(t.id) }
    }

    func setAllPaused(_ paused: Bool) {
        perform { await $0.setAllPaused(paused) }
    }

    func revealWorkspace(_ t: TopsideTask) {
        let path = t.workspace?.path ?? t.repo
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copy(_ text: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("已复制\(what)")
    }

    private func perform(_ action: @escaping @Sendable (TaskEngine) async throws -> Void) {
        guard let engine = host.engine else { show(host.statusText); return }
        Task {
            do { try await action(engine) } catch { show("\(error)") }
        }
    }

    func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }
}
