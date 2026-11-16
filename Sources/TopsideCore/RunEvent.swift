import Foundation

/// The end of one agent turn, as reported by the agent's event stream.
/// A single run can contain several (M0: an agent took an extra turn when a
/// background subagent finished), so a run is finished only when its process
/// exits.
public struct TurnSummary: Codable, Sendable, Equatable {
    public var isError: Bool
    /// Agent-specific classification, e.g. "success", "error_max_budget_usd".
    public var kind: String?
    public var text: String?
    /// Cumulative cost of the session so far, when the agent reports one.
    public var costUSD: Double?
    public var tokens: Int?
    public var errors: [String]

    public init(isError: Bool, kind: String? = nil, text: String? = nil, costUSD: Double? = nil,
                tokens: Int? = nil, errors: [String] = []) {
        self.isError = isError
        self.kind = kind
        self.text = text
        self.costUSD = costUSD
        self.tokens = tokens
        self.errors = errors
    }
}

/// Agent-neutral events produced by a runner's parser from one line of output.
public enum RunEvent: Sendable, Equatable {
    case sessionStarted(id: String, model: String?)
    case toolStarted(id: String?, name: String, detail: String?)
    case toolFinished(id: String?, failed: Bool)
    case message(String)
    case permissionDenied(tool: String, reason: String?)
    case turnFinished(TurnSummary)
    case subagentStarted(id: String, kind: String?, description: String?)
    case subagentFinished(id: String, status: String?)
    /// Something worth showing in logs that does not change state.
    case notice(String)
}

/// How to start a process. Built by a runner, executed by the engine.
public struct ProcessSpec: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    /// Written to a file and connected to the process's stdin. Prompts go
    /// here rather than in argv: no length limit, no confusion with flags,
    /// and not visible to other users through `ps`.
    public var standardInput: String?

    public init(executable: String, arguments: [String], environment: [String: String],
                workingDirectory: String, standardInput: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
    }
}

public struct AgentLaunchRequest: Sendable, Equatable {
    public var prompt: String
    public var workspacePath: String
    public var access: AccessLevel
    /// Continue this session instead of starting a new one.
    public var resumeSessionID: String?
    /// For agents that accept a caller-chosen session id on a new session.
    public var newSessionID: String
    public var model: String?
    public var budgetUSD: Double?

    public init(prompt: String, workspacePath: String, access: AccessLevel, resumeSessionID: String? = nil,
                newSessionID: String = UUID().uuidString.lowercased(), model: String? = nil, budgetUSD: Double? = nil) {
        self.prompt = prompt
        self.workspacePath = workspacePath
        self.access = access
        self.resumeSessionID = resumeSessionID
        self.newSessionID = newSessionID
        self.model = model
        self.budgetUSD = budgetUSD
    }
}

public struct AgentInstallation: Sendable, Equatable {
    public var executable: String
    public var version: String?

    public init(executable: String, version: String?) {
        self.executable = executable
        self.version = version
    }
}

public enum RunnerCapability: String, Sendable {
    /// The engine can choose the session id before launch.
    case presetSessionID
    case costReporting
    case budgetLimit
    case review
}

/// One implementation per agent (design doc 8.1). Everything agent-specific
/// lives behind this protocol, so the engine never names an agent.
public protocol AgentRunner: Sendable {
    var kind: AgentKind { get }
    var displayName: String { get }
    var capabilities: Set<RunnerCapability> { get }

    /// Find the agent's executable, or nil if it is not installed.
    func detect(searchPath: String?) -> AgentInstallation?

    /// The command line for one run. `baseEnvironment` is the engine's environment;
    /// the runner removes anything that must not leak into the agent.
    func launchSpec(for request: AgentLaunchRequest, executable: String,
                    baseEnvironment: [String: String]) -> ProcessSpec

    /// Turn one line of the agent's stdout into zero or more events.
    /// Must never throw: unknown or malformed input yields [] or a notice.
    func parse(line: Data) -> [RunEvent]

    /// Shell command that reopens the session in a terminal.
    func takeoverCommand(sessionID: String) -> String
}

extension AgentRunner {
    public func detect() -> AgentInstallation? { detect(searchPath: ProcessInfo.processInfo.environment["PATH"]) }
}
