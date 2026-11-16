import Foundation
import TopsideCore
import TopsideEngine

/// "查看活动": the latest things the agent did, read from the current run's
/// event file (design doc 6.6).
public enum Activity {
    /// How much of the end of the file to read. Enough for dozens of events;
    /// a single huge line (a long message) may be cut off and is then skipped.
    static let tailBytes: UInt64 = 64 * 1024

    public static func recent(_ task: TopsideTask, runner: any AgentRunner, limit: Int = 8) -> [String] {
        guard let run = task.currentRun ?? task.steps.flatMap(\.runs).last else { return [] }
        let file = URL(fileURLWithPath: run.directory).appendingPathComponent(ProcessSupervisor.Files.events)
        return recent(file: file, runner: runner, limit: limit)
    }

    public static func recent(file: URL, runner: any AgentRunner, limit: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > tailBytes ? size - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // probably starts mid-line
        var out: [String] = []
        for line in lines {
            for e in runner.parse(line: Data(line)) { if let s = describe(e) { out.append(s) } }
        }
        return Array(out.suffix(limit))
    }

    public static func describe(_ e: RunEvent) -> String? {
        switch e {
        case .sessionStarted(_, let model): return "会话开始" + (model.map { "（\($0)）" } ?? "")
        case .toolStarted(_, let name, let detail): return "→ \(name)" + (detail.map { " " + UIText.oneLine($0, limit: 100) } ?? "")
        case .toolFinished(_, let failed): return failed ? "  ✕ 工具调用失败" : nil
        case .message(let text): return "“\(UIText.oneLine(text, limit: 160))”"
        case .permissionDenied(let tool, let reason):
            return "✕ 被拒绝 \(tool)" + (reason.map { "：" + UIText.oneLine($0, limit: 100) } ?? "")
        case .turnFinished(let s):
            return s.isError ? "这一轮失败：\(s.errors.first ?? s.kind ?? "")" : "这一轮结束"
        case .subagentStarted(_, let kind, let d):
            return "↳ 子 agent \(kind ?? "")" + (d.map { "：" + UIText.oneLine($0, limit: 80) } ?? "")
        case .subagentFinished(_, let status): return "↳ 子 agent \(status ?? "结束")"
        case .notice(let text): return "注意：\(UIText.oneLine(text, limit: 120))"
        }
    }
}
