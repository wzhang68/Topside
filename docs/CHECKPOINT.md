# Checkpoint

> 更新：2026-11-16。新开 session 时先读这份文件，再按需读 `design.md`、`development-plan.md`、`m0-findings.md`。

## 当前进度

| 里程碑 | 状态 |
|--------|------|
| M0 技术验证 | 我能做的部分已完成。还有三件需要你来做（见“等你做的事”） |
| M1 任务引擎和命令行 | **完成**。见 `development-plan.md` 第 8 节 |
| M2 岛与派活 | **代码完成，等你在真机上检查**。结果和测量见 `development-plan.md` 第 9 节 |

M2 的改动已按内容分成 4 个提交推送：界面模型 `TopsideUIModel`；引擎的 `LoginEnvironment`；应用和 CI 的应用构建步骤；调试工具和文档。

## CI

最新一次运行（`9bb11e2`）全绿：58 个测试 13.7 秒通过。更早的两次（`6e5c521`、`d82da57`）停在“进行中”，它们在超时设置之前开始，会被 GitHub 在 6 小时上限时结束，也可以在 Actions 页面手动取消（本机 `gh` 没登录）。M2 起 CI 多了一步“Build the app”（XcodeGen + xcodebuild，不签名）。新 session 先确认这一步在 CI 上通过。

查询命令（不需要登录；匿名 API 每小时有次数限制，403 就是用完了）：

```bash
python3 -I - <<'EOF'
import json, urllib.request
get = lambda u: json.load(urllib.request.urlopen(u, timeout=20))
for r in get("https://api.github.com/repos/wzhang68/Topside/actions/runs?per_page=3")["workflow_runs"]:
    print(r["head_sha"][:7], r["status"], r["conclusion"], r["html_url"])
    for job in get(r["jobs_url"])["jobs"]:
        print("  ", ", ".join(f'{s["name"]}={s["conclusion"]}' for s in job["steps"]))
        for a in get(f'https://api.github.com/repos/wzhang68/Topside/check-runs/{job["id"]}/annotations'):
            print("   -", a["title"], "|", a["message"][:200])
EOF
```

## 等你做的事

1. **M2 的真机检查**（用真实数据目录前，先用 `scripts/demo-island.sh` 试）：
   - 在任意应用里按 `⌥Space`，打字（包括中文输入法），回车：任务出现在岛上，焦点回到原应用。`Esc` 取消同样归还焦点。`⌘↩` 派出后输入框不收起。
   - `@` 加几个字母选仓库（`↑↓` 选择，`↩`/`⇥` 确认）；把一个仓库文件夹拖到岛上。
   - `⇥` 在选项间移动，`←→` 改选项；点选项弹出菜单。
   - 悬停展开、移开收起；点击岛旁边的透明区域落到下面的窗口；`⋯` 菜单打开时岛不收起。
   - 内建刘海屏：收起态包住刘海；插拔外接显示器后岛移到新的主屏。
   - 全屏应用和切换 Space 时岛仍可见。
   - 停掉 `topside serve`，打开应用，同时派 3 个真实任务，对照 `topside list`。
2. **在 Codex 里信任 Topside 的 hook**（影响 M3）：命令见 `m0-findings.md` 结论 2。
3. **试用 CodeIsland 和 Conductor**（确认定位）。
4. **告诉我你常用的编辑器**（M4 之前要；终端已知是 Ghostty）。

M0 的窗口原型检查（`Spikes/m0-window`）已经被第 1 项取代：同样的检查直接在应用上做。

## 工作约定（这个项目里定下的）

- **提交和推送：** 用你的 git 身份（`wzhang68`），提交信息里**不加** Claude 的署名。只在你要求时提交和推送。推送前跑全量测试，**测试不过就停**，不推送。提交按内容拆分，每个提交单独能编译。
- **仓库是公开的：** 推送前运行 `scripts/check-no-private-data.sh --history`。原始录制不进仓库，夹具先用 `scripts/scrub-fixtures.py` 脱敏。
- **这台机器上 PATH 里有“遮蔽”：** `/usr/local/bin/git` 是 2018 年的 2.16（Topside 会自己选 `/usr/bin/git` 2.50）；`sample` 是 conda 的同名脚本，系统的在 `/usr/bin/sample`。手动命令里用完整路径。
- **测试：** `swift test`（约 5 秒，92 个测试，不调用模型）。性能测试默认跳过：`TOPSIDE_PERF=1 swift test --filter engineCPU`。
- **构建应用：** `xcodegen generate --spec App/project.yml`，然后 `xcodebuild -project App/Topside.xcodeproj -scheme Topside -derivedDataPath .build/xcode build`。工程文件不进仓库。
- **界面调试：** `scripts/demo-island.sh [任务数] [--no-build]`，`--stop` 清理。它会占用 `⌥Space`，并在你点别处时关掉输入框（这是设计行为）。`TOPSIDE_ISLAND_START=expanded|launcher` 以展开态或输入框启动；截图用 `/usr/sbin/screencapture -x -R x,y,w,h`。
- **用真实 agent 做端到端测试时：** 设置 `TOPSIDE_HOME` 和 `TOPSIDE_WORKTREES` 指向临时目录，不要碰你真实的数据目录；用便宜模型（Claude `--model haiku --budget 0.10`，Codex `--model gpt-6-luna`）。
- **验证脚本里不用 `--dangerously-bypass-hook-trust`**（会被安全检查拦下，产品也不用）。
- **界面文字是中文**，集中在 `TopsideUIModel/TaskRow.swift` 的 `UIText` 和视图里，以后做本地化时再抽出。

## 关键文件

| 文件 | 内容 |
|------|------|
| `docs/design.md` | 设计文档（v0.5） |
| `docs/development-plan.md` | 里程碑；第 8 节 M1 完成情况，第 9 节 M2 进展 |
| `docs/m0-findings.md` | M0 验证结论，含 Codex 信任步骤 |
| `Sources/TopsideCore/TaskMachine.swift` | 任务状态机（纯函数） |
| `Sources/TopsideEngine/TaskEngine.swift` | 引擎 |
| `Sources/TopsideEngine/LoginEnvironment.swift` | 应用向登录 shell 要环境变量 |
| `Sources/TopsideRunners/` | Claude Code 和 Codex 的命令行与解析 |
| `Sources/TopsideUIModel/` | 刘海几何、列表、任务行、派活输入框的状态（有测试） |
| `App/project.yml` | 应用工程（XcodeGen） |
| `App/Topside/EngineHost.swift` | 应用内嵌引擎、单引擎检查 |
| `App/Topside/Window/IslandController.swift` | 面板、悬停、点击穿透、快捷键、焦点归还 |
| `App/Topside/IslandModel.swift` | 界面状态和动作 |
| `Sources/topside/main.swift` | 命令行 |
| `scripts/demo-island.sh` | 用假 agent 驱动应用 |
| `Tests/Fixtures/` | 脱敏后的真实 agent 事件流 |
