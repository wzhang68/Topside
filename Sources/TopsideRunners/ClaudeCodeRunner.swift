import Foundation
import TopsideCore

extension AgentKind {
    public static let claudeCode = AgentKind("claude-code")
}

/// Runs Claude Code headless: `claude -p --output-format stream-json`.
/// Behaviour verified in M0 against Claude Code 2.1.325 (Tests/Fixtures/claude-code).
public struct ClaudeCodeRunner: AgentRunner {
    public let kind = AgentKind.claudeCode
    public let displayName = "Claude"
    public let capabilities: Set<RunnerCapability> = [.presetSessionID, .costReporting, .budgetLimit]

    /// Overrides the executable search (used by tests and by a settings override).
    public var executableOverride: String?
    /// Extra arguments appended to every launch (e.g. `--settings` for hooks, from M3).
    public var extraArguments: [String]

    public init(executableOverride: String? = nil, extraArguments: [String] = []) {
        self.executableOverride = executableOverride
        self.extraArguments = extraArguments
    }

    public func detect(searchPath: String?) -> AgentInstallation? {
        guard let exe = executableOverride ?? Executables.find("claude", searchPath: searchPath) else { return nil }
        return AgentInstallation(executable: exe, version: executableOverride == nil ? Executables.version(of: exe) : nil)
    }

    public func launchSpec(for request: AgentLaunchRequest, executable: String,
                           baseEnvironment: [String: String]) -> ProcessSpec {
        // The prompt arrives on stdin (see ProcessSpec.standardInput).
        var args = ["-p", "--output-format", "stream-json", "--verbose"]
        switch request.access {
        case .readOnly: args += ["--permission-mode", "plan"]
        case .workspace: args += ["--permission-mode", "acceptEdits"]
        }
        // Nobody answers permission prompts yet: anything that would prompt is
        // denied (M1). M3 replaces this with the PermissionRequest hook.
        args += ["--permission-prompts", "none"]
        if let resume = request.resumeSessionID {
            args += ["--resume", resume]
        } else {
            args += ["--session-id", request.newSessionID]
        }
        if let model = request.model { args += ["--model", model] }
        if let budget = request.budgetUSD { args += ["--max-budget-usd", String(budget)] }
        args += extraArguments
        return ProcessSpec(executable: executable, arguments: args,
                           environment: cleanEnvironment(baseEnvironment),
                           workingDirectory: request.workspacePath, standardInput: request.prompt)
    }

    public func takeoverCommand(sessionID: String) -> String {
        "claude --resume \(sessionID)"
    }

    public func parse(line: Data) -> [RunEvent] {
        guard let d = jsonObject(line) else { return [] }
        let type = d.string("type")
        let subtype = d.string("subtype")

        switch (type, subtype) {
        case ("system", "init"):
            guard let id = d.string("session_id") else { return [] }
            return [.sessionStarted(id: id, model: d.string("model"))]

        case ("system", "permission_denied"):
            return [.permissionDenied(tool: d.string("tool_name") ?? "tool", reason: d.string("message"))]

        case ("system", "task_started"):
            // local_agent = a subagent; local_bash = a backgrounded shell command.
            guard let id = d.string("task_id") else { return [] }
            if d.string("task_type") == "local_agent" || d.string("subagent_type") != nil {
                return [.subagentStarted(id: id, kind: d.string("subagent_type"), description: d.string("description"))]
            }
            return [.toolStarted(id: id, name: "Background", detail: d.string("description"))]

        case ("system", "task_notification"):
            guard let id = d.string("task_id") else { return [] }
            return [.subagentFinished(id: id, status: d.string("status"))]

        case ("assistant", _):
            let content = d.dict("message")?.array("content") ?? []
            return content.compactMap { item -> RunEvent? in
                switch item.string("type") {
                case "tool_use":
                    return .toolStarted(id: item.string("id"), name: item.string("name") ?? "tool",
                                        detail: briefDetail(item.dict("input")))
                case "text":
                    guard let text = item.string("text"), !text.isEmpty else { return nil }
                    return .message(text)
                default:
                    return nil
                }
            }

        case ("user", _):
            let content = d.dict("message")?.array("content") ?? []
            return content.compactMap { item in
                guard item.string("type") == "tool_result" else { return nil }
                return .toolFinished(id: item.string("tool_use_id"), failed: item.bool("is_error") ?? false)
            }

        case ("result", _):
            let usage = d.dict("usage")
            let tokens = [usage?.int("input_tokens"), usage?.int("output_tokens"),
                          usage?.int("cache_creation_input_tokens"), usage?.int("cache_read_input_tokens")]
                .compactMap { $0 }.reduce(0, +)
            let errors = (d["errors"] as? [String]) ?? []
            return [.turnFinished(TurnSummary(
                isError: d.bool("is_error") ?? (subtype != "success"),
                kind: subtype,
                text: d.string("result"),
                costUSD: d.double("total_cost_usd"),
                tokens: tokens > 0 ? tokens : nil,
                errors: errors))]

        default:
            return []
        }
    }
}
