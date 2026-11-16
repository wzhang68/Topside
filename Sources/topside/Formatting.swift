import Foundation
import TopsideCore

enum Format {
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "\(max(s, 0))s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    static func cost(_ usd: Double?) -> String? {
        usd.map { $0 < 0.01 ? String(format: "$%.4f", $0) : String(format: "$%.2f", $0) }
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > n ? String(flat.prefix(n - 1)) + "…" : flat
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }

    static func status(_ t: TopsideTask) -> String {
        if t.status == .running && t.paused { return "paused" }
        if t.status == .queued && t.startedAt != nil { return "preparing" }
        return t.status.rawValue
    }

    static func changes(_ r: TaskResult) -> String {
        r.files.isEmpty ? "no changes" : "\(r.files.count) file\(r.files.count == 1 ? "" : "s") +\(r.linesAdded) −\(r.linesDeleted)"
    }

    /// One line describing where the task is.
    static func detail(_ t: TopsideTask) -> String {
        switch t.status {
        case .ready:
            return t.result.map(changes) ?? ""
        case .failed:
            return t.failure?.message ?? "failed"
        case .closed:
            return t.outcome?.rawValue ?? "closed"
        case .running:
            if let run = t.currentRun {
                if let sub = run.activeSubagents.first { return "subagent \(sub.kind ?? "") \(sub.description ?? "")" }
                return run.activity ?? "working"
            }
            return "starting"
        case .queued:
            return t.startedAt == nil ? "waiting for a slot" : "preparing workspace"
        case .needsYou:
            return "needs you"
        }
    }

    static func listLine(_ t: TopsideTask, agentName: String) -> String {
        [pad(t.shortID, 9), pad(status(t), 10), pad(agentName, 7), pad(age(t.createdAt), 5),
         pad(clip(t.title, 34), 35), clip(detail(t), 60)].joined()
    }

    static func show(_ t: TopsideTask, agentName: String, takeover: String?) -> String {
        var lines = [
            "\(t.title)",
            "  id         \(t.id.uuidString.lowercased())",
            "  status     \(status(t))" + (t.failure.map { " — \($0.message)" } ?? ""),
            "  agent      \(agentName)" + (t.model.map { " (\($0))" } ?? ""),
            "  repo       \(t.repo)",
        ]
        if let ws = t.workspace {
            lines.append("  workspace  \(ws.path)")
            if let b = ws.branch { lines.append("  branch     \(b) (from \(ws.baseCommit.prefix(10)))") }
        } else {
            lines.append("  workspace  \(t.mode == .inPlace ? "in place" : "not created yet")")
        }
        lines.append("  created    \(t.createdAt.formatted(date: .abbreviated, time: .standard))")
        if let c = cost(t.totalCostUSD) { lines.append("  cost       \(c)") }
        if t.totalPermissionDenials > 0 {
            lines.append("  denied     \(t.totalPermissionDenials) permission request(s) (approvals arrive in M3)")
        }
        if let run = t.currentRun {
            lines.append("  run        #\(run.number), pid \(run.pid.map(String.init) ?? "-")"
                         + (run.exitCode.map { ", exit \($0)" } ?? (run.isFinished ? "" : ", running")))
            if let a = run.activity, !run.isFinished { lines.append("  doing      \(clip(a, 100))") }
        }
        if let r = t.result {
            lines.append("  result     \(changes(r))")
            for f in r.files.prefix(20) {
                lines.append("               \(f.added.map { "+\($0)" } ?? "bin") \(f.deleted.map { "−\($0)" } ?? "") \(f.path)")
            }
            if r.files.count > 20 { lines.append("               … \(r.files.count - 20) more") }
        }
        if let s = t.currentRun?.summary ?? t.result?.summary {
            lines.append("  agent said \"\(clip(s, 400))\"")
        }
        if let d = t.failure?.detail, !d.isEmpty {
            lines.append("  output")
            lines += d.split(whereSeparator: \.isNewline).suffix(15).map { "    \($0)" }
        }
        if let takeover, let ws = t.workspace {
            lines.append("  take over  cd \(shellQuote(ws.path)) && \(takeover)")
        }
        return lines.joined(separator: "\n")
    }

    static func event(_ e: RunEvent) -> String? {
        switch e {
        case .sessionStarted(let id, let model): return "session \(id)" + (model.map { " (\($0))" } ?? "")
        case .toolStarted(_, let name, let detail): return "→ \(name)" + (detail.map { " \(clip($0, 140))" } ?? "")
        case .toolFinished(_, let failed): return failed ? "  ✗ tool failed" : nil
        case .message(let text): return "“\(clip(text, 300))”"
        case .permissionDenied(let tool, let reason): return "✗ denied \(tool)" + (reason.map { ": \(clip($0, 140))" } ?? "")
        case .turnFinished(let s):
            let c = cost(s.costUSD).map { ", \($0) so far" } ?? ""
            return s.isError ? "turn failed: \(s.errors.first ?? s.kind ?? "")" : "turn finished\(c)"
        case .subagentStarted(_, let kind, let d): return "↳ subagent \(kind ?? "")" + (d.map { ": \(clip($0, 120))" } ?? "")
        case .subagentFinished(_, let status): return "↳ subagent \(status ?? "finished")"
        case .notice(let text): return "note: \(clip(text, 200))"
        }
    }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-+".contains($0) }) ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
