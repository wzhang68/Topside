import Foundation

/// Identifies an agent by a short name. Core never names a specific agent;
/// each runner declares its own kind.
public struct AgentKind: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public typealias TaskID = UUID

/// Design doc 6.3. Ordered here by urgency (most urgent first).
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case needsYou, failed, ready, running, queued, closed

    /// Lower is more urgent. Used to sort the island's list.
    public var urgency: Int { Self.allCases.firstIndex(of: self)! }

    /// Statuses in which the task no longer changes on its own.
    public var isSettled: Bool { self == .failed || self == .ready || self == .closed }
}

public enum WorkspaceMode: String, Codable, Sendable {
    /// A new git worktree and topside/ branch (default).
    case isolated
    /// Run directly in the repository's own checkout.
    case inPlace
}

/// Where a task's workspace ended up once it was prepared.
public struct WorkspaceInfo: Codable, Sendable, Equatable {
    public var path: String
    /// nil for in-place workspaces.
    public var branch: String?
    public var baseCommit: String

    public init(path: String, branch: String?, baseCommit: String) {
        self.path = path
        self.branch = branch
        self.baseCommit = baseCommit
    }
}

/// Per-repository preparation, design doc 8.2.
public struct RepoSetup: Codable, Sendable, Equatable {
    /// Untracked files copied from the main checkout into a new worktree.
    public var copyFiles: [String]
    /// Directories cloned copy-on-write (APFS) into a new worktree. Only for path-independent caches.
    public var cloneDirectories: [String]
    /// Run once in a new worktree, e.g. "npm ci".
    public var prepCommand: String?
    /// Used by verify steps, e.g. "npm test".
    public var verifyCommand: String?

    public init(copyFiles: [String] = [], cloneDirectories: [String] = [],
                prepCommand: String? = nil, verifyCommand: String? = nil) {
        self.copyFiles = copyFiles
        self.cloneDirectories = cloneDirectories
        self.prepCommand = prepCommand
        self.verifyCommand = verifyCommand
    }
}

public enum AccessLevel: String, Codable, Sendable {
    case readOnly
    case workspace
}

public struct AgentStep: Codable, Sendable, Equatable {
    public var role: String
    public var access: AccessLevel
    /// "{{prompt}}" is replaced with the task's prompt.
    public var promptTemplate: String

    public init(role: String, access: AccessLevel, promptTemplate: String) {
        self.role = role
        self.access = access
        self.promptTemplate = promptTemplate
    }
}

public enum Step: Codable, Sendable, Equatable {
    case agent(AgentStep)
    /// Runs the repository's verify command. (Executed from M5.)
    case verify
    /// Waits for the user to confirm. (Executed from M5.)
    case gate(String)

    public var label: String {
        switch self {
        case .agent(let s): return s.role
        case .verify: return "verify"
        case .gate(let kind): return kind
        }
    }
}

public struct Recipe: Codable, Sendable, Equatable {
    public var name: String
    public var steps: [Step]

    public init(name: String, steps: [Step]) {
        self.name = name
        self.steps = steps
    }

    /// The only recipe the M1 engine runs: one agent step.
    public static let quick = Recipe(name: "quick", steps: [
        .agent(AgentStep(role: "implement", access: .workspace, promptTemplate: "{{prompt}}")),
    ])
}

public enum Interruption: String, Codable, Sendable {
    /// The user asked to stop the task.
    case user
    /// The engine stopped it (e.g. while discarding).
    case engine
}

public struct SubagentInfo: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String?
    public var description: String?
}

/// One process run of one agent step.
public struct RunRecord: Codable, Sendable, Equatable {
    public var number: Int
    /// Directory holding events.jsonl, stderr.log and exit-code.
    public var directory: String
    public var pid: Int32?
    /// Process start time; together with pid it identifies the process across restarts.
    public var processStartTime: Double?
    public var sessionID: String?
    public var launchedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var interruption: Interruption?
    /// Bytes of events.jsonl already applied to this record.
    public var eventsOffset: UInt64
    /// What the agent is doing right now, e.g. "Bash npm test".
    public var activity: String?
    /// The agent's latest message, or its final result text.
    public var summary: String?
    public var costUSD: Double?
    public var tokens: Int?
    public var permissionDenials: Int
    public var turnCount: Int
    public var lastTurnIsError: Bool?
    public var turnErrors: [String]
    public var activeSubagents: [SubagentInfo]

    public init(number: Int, directory: String, launchedAt: Date) {
        self.number = number
        self.directory = directory
        self.launchedAt = launchedAt
        self.eventsOffset = 0
        self.permissionDenials = 0
        self.turnCount = 0
        self.turnErrors = []
        self.activeSubagents = []
    }

    public var isFinished: Bool { endedAt != nil }
}

public enum StepStatus: String, Codable, Sendable {
    case pending, running, succeeded, failed
}

public struct StepState: Codable, Sendable, Equatable {
    public var status: StepStatus
    public var runs: [RunRecord]

    public init(status: StepStatus = .pending, runs: [RunRecord] = []) {
        self.status = status
        self.runs = runs
    }
}

public struct FileChange: Codable, Sendable, Equatable {
    public var path: String
    /// nil for binary files.
    public var added: Int?
    public var deleted: Int?

    public init(path: String, added: Int?, deleted: Int?) {
        self.path = path
        self.added = added
        self.deleted = deleted
    }
}

/// Design doc 8.5: computed by Topside, not taken from the agent's word.
public struct TaskResult: Codable, Sendable, Equatable {
    public var files: [FileChange]
    public var summary: String?
    public var costUSD: Double?
    public var permissionDenials: Int

    public init(files: [FileChange], summary: String?, costUSD: Double?, permissionDenials: Int) {
        self.files = files
        self.summary = summary
        self.costUSD = costUSD
        self.permissionDenials = permissionDenials
    }

    public var linesAdded: Int { files.compactMap(\.added).reduce(0, +) }
    public var linesDeleted: Int { files.compactMap(\.deleted).reduce(0, +) }
}

public enum FailureKind: String, Codable, Sendable {
    case workspace
    case agent
    case stopped
    case lost
    case unsupported
    case result
}

public struct Failure: Codable, Sendable, Equatable {
    public var kind: FailureKind
    public var message: String
    /// Tail of the relevant output, if any.
    public var detail: String?

    public init(kind: FailureKind, message: String, detail: String? = nil) {
        self.kind = kind
        self.message = message
        self.detail = detail
    }
}

public enum Outcome: String, Codable, Sendable {
    case discarded
}

public struct TopsideTask: Codable, Sendable, Equatable, Identifiable {
    public let id: TaskID
    public var title: String
    public var prompt: String
    public var repo: String
    public var agent: AgentKind
    public var model: String?
    public var budgetUSD: Double?
    public var mode: WorkspaceMode
    public var setup: RepoSetup
    public var recipe: Recipe
    public var workspace: WorkspaceInfo?
    public var steps: [StepState]
    public var currentStep: Int?
    public var status: TaskStatus
    /// Set when the engine starts preparing the workspace; nil while waiting for a slot.
    public var startedAt: Date?
    public var stopRequested: Bool
    public var paused: Bool
    public var result: TaskResult?
    public var failure: Failure?
    public var outcome: Outcome?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: TaskID = TaskID(), prompt: String, repo: String, agent: AgentKind,
                model: String? = nil, budgetUSD: Double? = nil, mode: WorkspaceMode = .isolated,
                setup: RepoSetup = RepoSetup(), recipe: Recipe = .quick, now: Date = Date()) {
        self.id = id
        self.title = TopsideTask.makeTitle(from: prompt)
        self.prompt = prompt
        self.repo = repo
        self.agent = agent
        self.model = model
        self.budgetUSD = budgetUSD
        self.mode = mode
        self.setup = setup
        self.recipe = recipe
        self.steps = recipe.steps.map { _ in StepState() }
        self.status = .queued
        self.stopRequested = false
        self.paused = false
        self.createdAt = now
        self.updatedAt = now
    }

    public static func makeTitle(from prompt: String, limit: Int = 48) -> String {
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed.isEmpty ? "Untitled task" : trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }

    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    /// The run currently executing (or last executed) for the current step.
    public var currentRun: RunRecord? {
        guard let i = currentStep, steps.indices.contains(i) else { return nil }
        return steps[i].runs.last
    }

    /// Started and not yet settled: counts against the concurrency limit.
    public var isActive: Bool { startedAt != nil && !status.isSettled }

    public var totalCostUSD: Double? {
        let costs = steps.flatMap(\.runs).compactMap(\.costUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    public var totalPermissionDenials: Int { steps.flatMap(\.runs).map(\.permissionDenials).reduce(0, +) }
}
