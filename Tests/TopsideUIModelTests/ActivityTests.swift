import Foundation
import Testing
import TopsideCore
@testable import TopsideUIModel

/// Parses "tool <name> <detail>" and "say <text>" lines.
private struct LineRunner: AgentRunner {
    let kind = AgentKind("lines")
    let displayName = "Lines"
    let capabilities: Set<RunnerCapability> = []
    func detect(searchPath: String?) -> AgentInstallation? { nil }
    func launchSpec(for request: AgentLaunchRequest, executable: String, baseEnvironment: [String: String]) -> ProcessSpec {
        ProcessSpec(executable: executable, arguments: [], environment: [:], workingDirectory: "/")
    }
    func parse(line: Data) -> [RunEvent] {
        let parts = String(decoding: line, as: UTF8.self).split(separator: " ", maxSplits: 2).map(String.init)
        switch parts.first {
        case "tool": return [.toolStarted(id: nil, name: parts[1], detail: parts.count > 2 ? parts[2] : nil)]
        case "say": return [.message(parts.dropFirst().joined(separator: " "))]
        default: return []
        }
    }
    func takeoverCommand(sessionID: String) -> String { "" }
}

@Suite struct ActivityTests {
    @Test func readsTheLatestEventsOfTheCurrentRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("topside-act-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = (1...20).map { "tool Bash npm test \($0)" } + ["noise", "say all done"]
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("events.jsonl"),
                                                        atomically: true, encoding: .utf8)
        var t = TopsideTask(prompt: "x", repo: "/r", agent: AgentKind("lines"))
        t.currentStep = 0
        t.steps[0].runs = [RunRecord(number: 1, directory: dir.path, launchedAt: Date())]
        let recent = Activity.recent(t, runner: LineRunner(), limit: 3)
        #expect(recent == ["→ Bash npm test 19", "→ Bash npm test 20", "“all done”"])
    }

    @Test func aLargeFileIsReadFromItsTail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("topside-act-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("events.jsonl")
        let body = (1...5000).map { "say message number \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
        try (body + "\n").write(to: file, atomically: true, encoding: .utf8)
        let recent = Activity.recent(file: file, runner: LineRunner(), limit: 2)
        #expect(recent.count == 2)
        #expect(recent.last?.contains("message number 5000") == true)
    }

    @Test func missingFileMeansNoActivity() {
        let t = TopsideTask(prompt: "x", repo: "/r", agent: AgentKind("lines"))
        #expect(Activity.recent(t, runner: LineRunner()).isEmpty)
    }
}
