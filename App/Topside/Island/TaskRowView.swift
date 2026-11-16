import SwiftUI
import TopsideCore
import TopsideUIModel

/// One task: status, title, agent, what it is doing, how long, and the ⋯ menu.
struct TaskRowView: View {
    let model: IslandModel
    let task: TopsideTask
    /// Shown when the list mixes repositories and is not grouped.
    let repoName: String?

    var body: some View {
        let row = TaskRow(task, agentName: model.host.displayName(task.agent), repoName: repoName ?? "")
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                StatusIcon(symbol: row.symbol)
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(row.agentName).font(.system(size: 11)).foregroundStyle(.gray)
                Elapsed(row: row)
                TaskMenu(model: model, task: task)
            }
            HStack(spacing: 6) {
                if let repoName { Text(repoName).foregroundStyle(.gray.opacity(0.8)) }
                if let steps = row.steps { Text(steps).foregroundStyle(.gray) }
                Text(row.detail)
                    .foregroundStyle(row.symbol == .failed ? Color.red.opacity(0.85) : .gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
            .padding(.leading, 24)

            if model.activityShown == task.id { activity }
            if model.confirmingDiscard == task.id { confirmDiscard }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    private var activity: some View {
        let lines = model.activity(task)
        return VStack(alignment: .leading, spacing: 2) {
            if lines.isEmpty { Text("还没有活动").foregroundStyle(.gray) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.leading, 24)
        .padding(.top, 2)
    }

    private var confirmDiscard: some View {
        HStack(spacing: 10) {
            Text(task.mode == .isolated ? "丢弃后会删除工作区和分支。" : "丢弃后任务关闭，原地改动保留在仓库里。")
                .foregroundStyle(.orange)
            Spacer()
            Button("取消") { model.confirmingDiscard = nil }
            Button("丢弃") { model.discard(task) }.foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .padding(.leading, 24)
        .padding(.top, 2)
    }
}

struct StatusIcon: View {
    let symbol: RowSymbol

    var body: some View {
        Group {
            switch symbol {
            case .needsYou:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .symbolEffect(.pulse, options: .repeating)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .running: Spinner()
            case .paused: Image(systemName: "pause.circle").foregroundStyle(.white.opacity(0.8))
            case .preparing: Image(systemName: "circle.dashed").foregroundStyle(.gray)
            case .waiting, .closed: Image(systemName: "circle").foregroundStyle(.gray)
            }
        }
        .font(.system(size: 13))
        .frame(width: 16)
    }
}

/// ◐ turning: a quarter turn a second, eased. A continuous rotation looked
/// smoother but redrew every row every frame (about 25% CPU with 30 running tasks).
struct Spinner: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate)
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.white)
                .rotationEffect(.degrees(Double(step) * 90))
                .animation(.easeInOut(duration: 0.35), value: step)
        }
    }
}

/// The clock ticks once a second, and only for rows that are still going.
struct Elapsed: View {
    let row: TaskRow

    var body: some View {
        Group {
            if row.isLive {
                TimelineView(.periodic(from: row.startedAt, by: 1)) { context in
                    Text(UIText.shortDuration(row.elapsed(now: context.date)))
                }
            } else if row.symbol != .waiting {
                Text(UIText.shortDuration(row.elapsed(now: Date())))
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.gray)
        .frame(minWidth: 34, alignment: .trailing)
    }
}

/// The ⋯ menu: actions that map directly onto the engine (design doc 6.6).
struct TaskMenu: View {
    let model: IslandModel
    let task: TopsideTask

    var body: some View {
        Menu {
            Button(model.activityShown == task.id ? "收起活动" : "查看活动") { model.toggleActivity(task) }
            if task.status == .running {
                Button(task.paused ? "继续" : "暂停") { model.setPaused(task, !task.paused) }
            }
            if task.isActive || task.status == .queued {
                Button("停止") { model.stop(task) }
            }
            Divider()
            Button("在 Finder 中打开工作区") { model.revealWorkspace(task) }
                .disabled(task.workspace == nil && task.mode == .isolated)
            if let branch = task.workspace?.branch {
                Button("复制分支名") { model.copy(branch, what: "分支名") }
            }
            if let path = task.workspace?.path {
                Button("复制工作区路径") { model.copy(path, what: "工作区路径") }
            }
            Divider()
            Button("丢弃任务…") { model.confirmingDiscard = task.id }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.gray)
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
