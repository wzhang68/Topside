import Foundation
import Testing
@testable import TopsideCore
@testable import TopsideRunners

private let runner = ClaudeCodeRunner()
private let dir = "claude-code/2.1.325"

@Suite struct ClaudeCodeParsingTests {
    @Test func allowRunsTheCommand() throws {
        let events = try Fixtures.events(runner, "\(dir)/allow/events.jsonl")
        #expect(events.contains { if case .sessionStarted = $0 { true } else { false } })
        #expect(events.contains(.toolStarted(id: events.compactMap { if case .toolStarted(let id, "Bash", _) = $0 { id } else { nil } }.first,
                                             name: "Bash", detail: "touch created_by_agent.txt")))
        let r = try Fixtures.record(runner, "\(dir)/allow/events.jsonl")
        #expect(r.summary == "DONE")
        #expect(r.lastTurnIsError == false)
        #expect(r.permissionDenials == 0)
        #expect((r.costUSD ?? 0) > 0)
        #expect(r.sessionID != nil)
    }

    @Test func denialsAreCounted() throws {
        for scenario in ["silent", "deny", "timeout"] {
            let r = try Fixtures.record(runner, "\(dir)/\(scenario)/events.jsonl")
            #expect(r.permissionDenials == 1, "\(scenario)")
            #expect(r.lastTurnIsError == false, "\(scenario): a denial is not an error turn")
        }
        let events = try Fixtures.events(runner, "\(dir)/deny/events.jsonl")
        #expect(events.contains(.permissionDenied(tool: "Bash", reason: "Denied by the Topside M0 spike.")))
    }

    @Test func subagentRunHasTwoTurnsAndATrackedSubagent() throws {
        let events = try Fixtures.events(runner, "\(dir)/subagent/events.jsonl")
        let turns = events.filter { if case .turnFinished = $0 { true } else { false } }
        #expect(turns.count == 2)
        #expect(events.contains { if case .subagentStarted(_, "Explore", _) = $0 { true } else { false } })
        let r = try Fixtures.record(runner, "\(dir)/subagent/events.jsonl")
        #expect(r.turnCount == 2)
        #expect(r.summary == "README.md")
        #expect(r.activeSubagents.isEmpty)
    }

    @Test func budgetExceededIsAnErrorTurn() throws {
        let r = try Fixtures.record(runner, "\(dir)/budget/events.jsonl")
        #expect(r.lastTurnIsError == true)
        #expect(r.turnErrors == ["Reached maximum budget ($0.0005)"])
    }

    @Test func stoppedRunLooksSuccessfulFromTheOutputAlone() throws {
        // The agent backgrounded `sleep 40`, ended its turn with a *success*
        // result, and was interrupted while waiting for it (exit code 0). Only
        // the engine's own record of sending the signal tells this apart from
        // a normal finish.
        for scenario in ["sigint", "sigterm"] {
            let r = try Fixtures.record(runner, "\(dir)/\(scenario)/events.jsonl")
            #expect(r.turnCount == 1, "\(scenario)")
            #expect(r.lastTurnIsError == false, "\(scenario)")
        }
        // The backgrounded shell command is activity, not a subagent.
        let events = try Fixtures.events(runner, "\(dir)/sigint/events.jsonl")
        #expect(!events.contains { if case .subagentStarted = $0 { true } else { false } })
        #expect(events.contains { if case .toolStarted(_, "Background", _) = $0 { true } else { false } })
    }

    @Test func resumedSessionsKeepTheirId() throws {
        let original = try Fixtures.record(runner, "\(dir)/allow/events.jsonl").sessionID
        let followUp = try Fixtures.record(runner, "\(dir)/followup/events.jsonl").sessionID
        #expect(original != nil && original == followUp)
        let cont = try Fixtures.record(runner, "\(dir)/continue/events.jsonl")
        #expect(cont.summary == "DONE")
    }

    @Test func malformedInputNeverThrows() {
        #expect(runner.parse(line: Data()).isEmpty)
        #expect(runner.parse(line: Data("not json".utf8)).isEmpty)
        #expect(runner.parse(line: Data(#"{"type":"something_new"}"#.utf8)).isEmpty)
        #expect(runner.parse(line: Data(#"{"type":"assistant","message":{"content":"text"}}"#.utf8)).isEmpty)
    }
}

@Suite struct ClaudeCodeLaunchTests {
    let env = ["PATH": "/usr/bin", "HOME": "/Users/x", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "outer",
               "CLAUDE_CONFIG_DIR": "/cfg"]

    @Test func newSession() {
        let req = AgentLaunchRequest(prompt: "-starts with a dash", workspacePath: "/w", access: .workspace,
                                     newSessionID: "sid-1", model: "haiku", budgetUSD: 0.5)
        let spec = runner.launchSpec(for: req, executable: "/bin/claude", baseEnvironment: env)
        #expect(spec.arguments == ["-p", "--output-format", "stream-json", "--verbose",
                                   "--permission-mode", "acceptEdits", "--permission-prompts", "none",
                                   "--session-id", "sid-1", "--model", "haiku", "--max-budget-usd", "0.5"])
        #expect(spec.standardInput == "-starts with a dash")    // never in argv
        #expect(spec.workingDirectory == "/w")
        #expect(spec.environment["CLAUDECODE"] == nil)
        #expect(spec.environment["CLAUDE_CODE_SESSION_ID"] == nil)
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == "/cfg")
        #expect(spec.environment["PATH"] == "/usr/bin")
    }

    @Test func resumeAndReadOnly() {
        let req = AgentLaunchRequest(prompt: "p", workspacePath: "/w", access: .readOnly, resumeSessionID: "sid-9")
        let args = runner.launchSpec(for: req, executable: "/bin/claude", baseEnvironment: [:]).arguments
        #expect(args.contains("--resume") && args.contains("sid-9"))
        #expect(!args.contains("--session-id"))
        #expect(args[args.firstIndex(of: "--permission-mode")! + 1] == "plan")
    }
}
