import Foundation
import TopsideCore

extension AgentKind {
    public static let codex = AgentKind("codex")
}

/// Runs Codex headless: `codex exec --json`.
/// Behaviour verified in M0 against Codex 0.169.0 (Tests/Fixtures/codex).
///
/// Known gap (M0): commands Codex runs through its `exec` script tool do not
/// appear in `--json`, so activity shown for Codex can be incomplete.
public struct CodexRunner: AgentRunner {
    public let kind = AgentKind.codex
    public let displayName = "Codex"
    public let capabilities: Set<RunnerCapability> = [.review]

    public var executableOverride: String?
    /// Extra `-c key=value` style arguments (e.g. hooks, from M3).
    public var extraArguments: [String]

    public init(executableOverride: String? = nil, extraArguments: [String] = []) {
        self.executableOverride = executableOverride
        self.extraArguments = extraArguments
    }

    public func detect(searchPath: String?) -> AgentInstallation? {
        guard let exe = executableOverride ?? Executables.find("codex", searchPath: searchPath) else { return nil }
        return AgentInstallation(executable: exe, version: executableOverride == nil ? Executables.version(of: exe) : nil)
    }

    public func launchSpec(for request: AgentLaunchRequest, executable: String,
                           baseEnvironment: [String: String]) -> ProcessSpec {
        var args = ["exec", "--json", "-C", request.workspacePath]
        // workspace-write: writes outside the workspace (and temp dirs) fail
        // without asking (M0: no approval is requested, nothing is auto-approved).
        args += ["-s", request.access == .readOnly ? "read-only" : "workspace-write"]
        if let model = request.model { args += ["-m", model] }
        args += extraArguments
        if let resume = request.resumeSessionID {
            args += ["resume", resume]
        }
        args.append("-")   // read the prompt from stdin
        return ProcessSpec(executable: executable, arguments: args,
                           environment: cleanEnvironment(baseEnvironment),
                           workingDirectory: request.workspacePath, standardInput: request.prompt)
    }

    public func takeoverCommand(sessionID: String) -> String {
        "codex resume \(sessionID)"
    }

    public func parse(line: Data) -> [RunEvent] {
        guard let d = jsonObject(line) else { return [] }
        switch d.string("type") {
        case "thread.started":
            guard let id = d.string("thread_id") else { return [] }
            return [.sessionStarted(id: id, model: nil)]

        case "item.started":
            guard let item = d.dict("item"), item.string("type") == "command_execution" else { return [] }
            return [.toolStarted(id: item.string("id"), name: "Shell", detail: briefDetail(item))]

        case "item.completed":
            guard let item = d.dict("item") else { return [] }
            switch item.string("type") {
            case "command_execution":
                let code = item.int("exit_code")
                return [.toolFinished(id: item.string("id"), failed: code.map { $0 != 0 } ?? false)]
            case "agent_message":
                guard let text = item.string("text"), !text.isEmpty else { return [] }
                return [.message(text)]
            case "error":
                return item.string("message").map { [.notice($0)] } ?? []
            default:
                // reasoning, file changes, todo lists, ...: not needed for task state.
                return []
            }

        case "turn.completed":
            let usage = d.dict("usage")
            let tokens = [usage?.int("input_tokens"), usage?.int("output_tokens")].compactMap { $0 }.reduce(0, +)
            return [.turnFinished(TurnSummary(isError: false, kind: "completed", tokens: tokens > 0 ? tokens : nil))]

        case "turn.failed":
            let message = d.dict("error")?.string("message") ?? "The turn failed."
            return [.turnFinished(TurnSummary(isError: true, kind: "failed", errors: [message]))]

        case "error":
            return [.notice(d.string("message") ?? "error")]

        default:
            return []
        }
    }
}
