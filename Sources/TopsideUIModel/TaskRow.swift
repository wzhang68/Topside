import Foundation
import TopsideCore

/// The status icon of a row. Colour is never the only signal: each has its own shape (design doc 6.3).
public enum RowSymbol: String, Sendable, Equatable {
    case needsYou, failed, ready, running, paused, preparing, waiting, closed
}

/// What one row of the expanded island shows (design doc 6.2 ③).
public struct TaskRow: Sendable, Equatable, Identifiable {
    public var id: TaskID
    public var symbol: RowSymbol
    public var title: String
    public var agentName: String
    public var repoName: String
    /// One line: what the agent is doing, or where the task stands.
    public var detail: String
    /// "实现 ✓  验证 ◐" for multi-step recipes; nil for single-step ones.
    public var steps: String?
    /// The clock runs from here...
    public var startedAt: Date
    /// ...to here; nil while it is still running.
    public var endedAt: Date?

    public init(_ t: TopsideTask, agentName: String, repoName: String) {
        id = t.id
        symbol = Self.symbol(t)
        title = t.title
        self.agentName = agentName
        self.repoName = repoName
        detail = Self.detail(t)
        steps = Self.steps(t)
        startedAt = t.startedAt ?? t.createdAt
        endedAt = t.status.isSettled ? (t.steps.flatMap(\.runs).compactMap(\.endedAt).max() ?? t.updatedAt) : nil
    }

    /// Whether the row changes by itself over time (a running clock), so the view needs a timer.
    public var isLive: Bool { endedAt == nil && symbol != .waiting }

    public func elapsed(now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    static func symbol(_ t: TopsideTask) -> RowSymbol {
        switch t.status {
        case .needsYou: return .needsYou
        case .failed: return .failed
        case .ready: return .ready
        case .running: return t.paused ? .paused : .running
        case .queued: return t.startedAt == nil ? .waiting : .preparing
        case .closed: return .closed
        }
    }

    static func detail(_ t: TopsideTask) -> String {
        switch t.status {
        case .ready:
            return t.result.map(UIText.changes) ?? "已完成"
        case .failed:
            return t.failure?.message ?? "失败"
        case .closed:
            return t.outcome == .discarded ? "已丢弃" : "已关闭"
        case .needsYou:
            return "在等你"
        case .queued:
            return t.startedAt == nil ? "排队中" : "正在准备工作区"
        case .running:
            if t.paused { return "已暂停" }
            guard let run = t.currentRun else { return "正在启动" }
            if let sub = run.activeSubagents.first {
                return "子 agent " + [sub.kind, sub.description].compactMap { $0 }.joined(separator: " ")
            }
            return run.activity.map { UIText.oneLine($0, limit: 80) } ?? "工作中"
        }
    }

    static func steps(_ t: TopsideTask) -> String? {
        guard t.recipe.steps.count > 1 else { return nil }
        return zip(t.recipe.steps, t.steps).map { step, state in
            let mark: String
            switch state.status {
            case .pending: mark = "○"
            case .running: mark = "◐"
            case .succeeded: mark = "✓"
            case .failed: mark = "✕"
            }
            return "\(UIText.stepName(step)) \(mark)"
        }.joined(separator: "  ")
    }
}

/// User-facing wording, kept in one place so it can be localised later.
public enum UIText {
    public static func changes(_ r: TaskResult) -> String {
        r.files.isEmpty ? "没有改动" : "\(r.files.count) 个文件 +\(r.linesAdded) −\(r.linesDeleted)"
    }

    public static func stepName(_ step: Step) -> String {
        switch step.label {
        case "implement": return "实现"
        case "plan": return "计划"
        case "review": return "复查"
        case "verify": return "验证"
        default: return step.label
        }
    }

    public static func recipeName(_ recipe: Recipe) -> String {
        switch recipe.name {
        case "quick": return "快速"
        default: return recipe.name
        }
    }

    public static func mode(_ mode: WorkspaceMode) -> String {
        mode == .isolated ? "隔离" : "原地"
    }

    /// "8 秒", "4 分 12 秒", "1 小时 3 分".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) 分" : "\(s / 60) 分 \(s % 60) 秒" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600) 小时" : "\(s / 3600) 小时 \(m) 分"
    }

    /// Compact form for list rows: "8s", "4m", "1h3m".
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h\(m)m"
    }

    public static func oneLine(_ s: String, limit: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
