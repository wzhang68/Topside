import SwiftUI
import TopsideCore
import TopsideUIModel

/// The dispatch box (design doc 6.1): the request, then repository, agent,
/// recipe and workspace, each with a default.
struct LauncherView: View {
    @Bindable var model: IslandModel
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.frame(height: model.geometry.topBarHeight)
            TextField("描述一个任务，回车派出…", text: $model.draft.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .lineLimit(1...6)
                .focused($promptFocused)
                .onChange(of: model.focusRequest) { promptFocused = true }
                .onChange(of: model.draft.text) { model.draft.suggestionIndex = 0 }
            if !model.suggestions.isEmpty { suggestions }
            options
            hints
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var suggestions: some View {
        let names = RepoNames.displayNames(for: model.knownRepos.map(\.path))
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element.path) { i, repo in
                Button {
                    model.draft.suggestionIndex = i
                    model.acceptSuggestion()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.gray)
                        Text(names[repo.path] ?? RepoNames.base(repo.path)).foregroundStyle(.white)
                        Text(abbreviate(repo.path)).foregroundStyle(.gray).lineLimit(1).truncationMode(.head)
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(i == model.draft.suggestionIndex ? Color.white.opacity(0.14) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var options: some View {
        HStack(spacing: 8) {
            Chip(text: model.draft.repo.map { "@" + RepoNames.base($0) } ?? "@选择仓库",
                 focused: model.draft.focus == .repo, missing: model.draft.repo == nil) {
                ForEach(model.knownRepos, id: \.path) { repo in
                    Button(abbreviate(repo.path)) { model.draft.repo = repo.path }
                }
                if !model.knownRepos.isEmpty { Divider() }
                Button("添加文件夹…") { model.chooseFolder() }
            }
            Chip(text: model.draft.agent.map(model.host.displayName)
                    ?? (model.host.state == .starting ? "正在查找 agent…" : "没有找到 agent"),
                 focused: model.draft.focus == .agent, missing: model.draft.agent == nil) {
                ForEach(model.agents, id: \.self) { kind in
                    Button(model.host.displayName(kind)) { model.draft.agent = kind }
                }
            }
            Chip(text: "/" + UIText.recipeName(model.draft.recipe), focused: model.draft.focus == .recipe, missing: false) {
                Button(UIText.recipeName(.quick)) { model.draft.recipe = .quick }
                Text("更多配方在后续版本加入")
            }
            Chip(text: UIText.mode(model.draft.mode), focused: model.draft.focus == .mode, missing: false) {
                Button("隔离（新的 worktree 和分支）") { model.draft.mode = .isolated }
                Button("原地（直接在仓库里改）") { model.draft.mode = .inPlace }
            }
            Spacer()
            if model.submitting { ProgressView().controlSize(.small) }
        }
    }

    private var hints: some View {
        Group {
            if let message = model.launcherMessage {
                Text(message).foregroundStyle(message.hasPrefix("已派出") ? .green : .orange)
            } else {
                Text("↩ 派出   ⌘↩ 派出并继续   ⇧↩ 换行   @ 选仓库   ⇥ 切换选项   Esc 取消   ⌥Q 退出")
                    .foregroundStyle(.gray)
            }
        }
        .font(.system(size: 11))
        .lineLimit(2)
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// An option in the launcher's second row. Click for a menu; ⇥ to focus, ←→ to change.
struct Chip<Items: View>: View {
    let text: String
    let focused: Bool
    let missing: Bool
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(missing ? .orange : .white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(focused ? 0.22 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(focused ? 0.5 : 0), lineWidth: 1))
        }
        // .button + .plain keeps the custom label; .borderlessButton would strip its background.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
