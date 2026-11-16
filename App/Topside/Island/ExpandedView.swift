import SwiftUI
import TopsideCore
import TopsideUIModel

/// ③ Expanded: the task list, most urgent first, grouped by repository when long.
struct ExpandedView: View {
    let model: IslandModel
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.geometry.topBarHeight)
            let layout = model.store.layout
            if layout.allTasks.isEmpty {
                empty
            } else {
                ScrollView(.vertical) {
                    list(layout)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(listHeight, IslandStyle.maxListHeight(model.geometry)))
            }
            Divider().overlay(Color.white.opacity(0.12))
            footer
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text("没有进行中的任务").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            Text("按 ⌥Space 派活，或把仓库文件夹拖到这里").font(.system(size: 11)).foregroundStyle(.gray)
            if model.host.state != .running {
                Text(model.host.statusText).font(.system(size: 11)).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    @ViewBuilder private func list(_ layout: TaskListLayout) -> some View {
        let names = model.store.repoNames
        LazyVStack(alignment: .leading, spacing: 2) {
            switch layout {
            case .flat(let tasks):
                let showRepo = Set(tasks.map(\.repo)).count > 1
                ForEach(tasks) { t in
                    TaskRowView(model: model, task: t, repoName: showRepo ? names[t.repo] : nil)
                }
            case .grouped(let pinned, let groups):
                ForEach(pinned) { t in TaskRowView(model: model, task: t, repoName: names[t.repo]) }
                ForEach(groups) { g in
                    GroupHeader(group: g, collapsed: model.collapsedGroups.contains(g.id)) {
                        if model.collapsedGroups.contains(g.id) { model.collapsedGroups.remove(g.id) }
                        else { model.collapsedGroups.insert(g.id) }
                    }
                    if !model.collapsedGroups.contains(g.id) {
                        ForEach(g.tasks) { t in TaskRowView(model: model, task: t, repoName: nil) }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // The lazy stack keeps rows by task id; without this, rows made for the flat
        // list survive the switch to groups with their old repository labels.
        .id(layout.isGrouped)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { model.window?.openLauncher() } label: {
                Text("＋ 新任务  ⌥Space")
            }
            .buttonStyle(.plain)
            if let notice = model.notice {
                Text(notice).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            let c = model.store.counts
            if c.active > 0 { Text("\(c.active) 个运行中") }
        }
        .font(.system(size: 11))
        .foregroundStyle(.gray)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }
}

struct GroupHeader: View {
    let group: TaskGroup
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 10)
                Text(group.name).font(.system(size: 11, weight: .semibold))
                let c = group.counts
                Text([c.active > 0 ? "\(c.active) 运行中" : nil, c.failed > 0 ? "\(c.failed) 失败" : nil,
                      c.ready > 0 ? "\(c.ready) 待验收" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                Spacer()
            }
            .foregroundStyle(.gray)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}
