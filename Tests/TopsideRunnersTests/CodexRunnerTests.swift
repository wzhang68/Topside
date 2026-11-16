import Foundation
import Testing
@testable import TopsideCore
@testable import TopsideRunners

private let runner = CodexRunner()
private let dir = "codex/0.169.0"

@Suite struct CodexParsingTests {
    @Test func everyFixtureParsesToASessionAndATurn() throws {
        for scenario in ["untrusted", "sandbox-default", "sandbox-on-request", "resume", "review"] {
            let r = try Fixtures.record(runner, "\(dir)/\(scenario)/events.jsonl")
            #expect(r.sessionID != nil, "\(scenario)")
            #expect(r.turnCount == 1, "\(scenario)")
            #expect(r.lastTurnIsError == false, "\(scenario)")
            #expect(r.costUSD == nil, "\(scenario): Codex reports no cost")
        }
    }

    @Test func commandsBecomeToolEvents() throws {
        let events = try Fixtures.events(runner, "\(dir)/untrusted/events.jsonl")
        #expect(events.contains { if case .toolStarted(_, "Shell", let d?) = $0 { d.contains("touch") } else { false } })
        #expect(events.contains(.toolFinished(id: "item_1", failed: false)))
        #expect(events.contains(.notice("clamping SessionEnd hook timeout to 3s in /<session-flags>/config.toml")))
    }

    @Test func sandboxBlockIsOnlyVisibleInTheMessage() throws {
        // M0: the blocked command ran through the exec script tool and is absent from --json.
        let events = try Fixtures.events(runner, "\(dir)/sandbox-default/events.jsonl")
        #expect(!events.contains { if case .toolStarted = $0 { true } else { false } })
        let r = try Fixtures.record(runner, "\(dir)/sandbox-default/events.jsonl")
        #expect(r.summary?.contains("Operation not permitted") == true)
    }

    @Test func resumeKeepsTheThreadAndReviewProducesFindings() throws {
        let original = try Fixtures.record(runner, "\(dir)/sandbox-default/events.jsonl").sessionID
        let resumed = try Fixtures.record(runner, "\(dir)/resume/events.jsonl").sessionID
        #expect(original == resumed)
        let review = try Fixtures.record(runner, "\(dir)/review/events.jsonl")
        #expect(review.summary?.contains("[P1]") == true)
    }

    @Test func interruptedRunHasNoTurn() throws {
        let r = try Fixtures.record(runner, "\(dir)/sigint/events.jsonl")
        #expect(r.turnCount == 0)
        #expect(r.activity?.hasPrefix("Shell") == true)
    }

    @Test func failedTurn() {
        let events = runner.parse(line: Data(#"{"type":"turn.failed","error":{"message":"usage limit reached"}}"#.utf8))
        #expect(events == [.turnFinished(TurnSummary(isError: true, kind: "failed", errors: ["usage limit reached"]))])
    }
}

@Suite struct CodexLaunchTests {
    @Test func newAndResumed() {
        let req = AgentLaunchRequest(prompt: "fix it", workspacePath: "/w", access: .workspace, model: "m1")
        let spec = runner.launchSpec(for: req, executable: "/bin/codex", baseEnvironment: ["CLAUDECODE": "1"])
        #expect(spec.arguments == ["exec", "--json", "-C", "/w", "-s", "workspace-write", "-m", "m1", "-"])
        #expect(spec.standardInput == "fix it")
        #expect(spec.environment["CLAUDECODE"] == nil)

        var resumed = req
        resumed.resumeSessionID = "t-1"
        resumed.access = .readOnly
        let args = runner.launchSpec(for: resumed, executable: "/bin/codex", baseEnvironment: [:]).arguments
        #expect(args.suffix(3) == ["resume", "t-1", "-"])
        #expect(args.contains("read-only"))
    }
}
