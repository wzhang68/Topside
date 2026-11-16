# Topside

**在 Mac 的刘海上派活、跟踪、验收 coding agent 的任务。**

[English](README.md)

> **状态：早期开发中。** 任务引擎已经可以用命令行使用（里程碑 M1）：在终端里派 Claude Code 和 Codex 的任务，
> 每个任务在自己的 git worktree 里运行，可以查看结果。刘海上的岛是下一个里程碑，目前还没有可以安装的应用。见[路线图](#路线图)。

---

## 想法

同时跑几个 coding agent 时，真正需要你的只有三个时刻：说清楚要什么、回答 agent 的问题、判断结果对不对。其余都是杂务。Topside 想把杂务接过来。

1. **派活。** 在任何地方按快捷键，输入一句话，回车。Topside 在后台启动 Claude Code 或 Codex，不需要开终端。
2. **隔离。** 每个任务有自己的 git worktree 和 `topside/` 分支，并行的任务互不干扰，也不碰你正在用的工作目录。
3. **跟踪。** 屏幕顶部的岛显示每个任务走到了哪一步（计划 ✓ 实现 ◐ 验证 ○），只在需要你的时候出声。
4. **验收。** 任务完成后给出结果卡片，内容来自 Topside 自己的观察：真实的改动，以及你的验证命令是否通过，而不是 agent 说一句“做完了”。之后可以看 diff、追加指令、让**另一个** agent 复查、开 PR、合入或丢弃。

```
● 重构配置加载     Claude   想执行：rm -rf build/
                            [拒绝]  [允许]
◐ 加限流中间件     Claude   计划 ✓  实现 ◐  验证 ○
✓ 修复登录 bug     Codex    3 个文件  +42 −7  测试通过
                            [看 diff]  [让 Claude 复查]  [开 PR]
```

## 和现有工具的区别

附近已经有不错的工具。Topside 处在两类工具之间：

| | 刘海状态栏（如 CodeIsland） | 并行 agent 工作台（如 Conductor） | Topside |
|---|---|---|---|
| 单位 | 终端会话 | 工作区 | 任务 |
| 怎么开始一件事 | 自己去终端启动 agent | 在应用窗口里新建 | 任何地方按快捷键 |
| 平时在哪 | 刘海 | 独立窗口 | 刘海 |
| 做完之后 | agent 的最后一条回复 | 应用内看 diff | 带自有验证结果的结果卡片 |
| 多个 agent | 各自独立 | 各自独立 | 可以接力：一个实现，另一个复查 |

在 worktree 里跑 agent 这件事本身不新。Topside 想加上的是：不用切换窗口的形态、把验证作为一等步骤、跨 agent 接力。如果你主要想看自己在终端里启动的 agent，刘海状态栏更合适，两者可以同时使用。

## 安全模型

Topside 启动的 agent 没有终端，所以权限请求必须由它来回答。规则如下：

- **默认拒绝。** 应用没在运行、请求超时、任何环节出错，结果都是拒绝。Topside 从不替你批准。
- **被拒绝不会丢掉任务。** 任务停下来等你，“允许并继续”会带着这一次许可恢复 agent。
- v1 **没有“跳过所有确认”的模式**，也不建立第二套长期规则。
- **不修改你的 agent 配置。** hook 按次注入（Claude Code 用 `--settings`，Codex 用 `-c`）。Codex 只运行你信任过一次的 hook，在那之前 Codex 只靠沙箱运行，越界操作直接失败。Topside 从不使用 `--dangerously-bypass-hook-trust`。
- **worktree 隔离的是 git 状态，不是你的机器。** agent 执行的命令仍然能访问你的用户账户能访问的一切，所以审批始终开启。
- **只在本机运行。** 没有遥测。联网的只有 agent 本身，以及你点击“开 PR”时的 `git push` 和 `gh`。

## 支持的 agent

| agent | 状态 |
|-------|------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | 命令行可用（M1）；权限审批在 M3 |
| [Codex CLI](https://github.com/openai/codex) | 命令行可用（M1）；在它的 `workspace-write` 沙箱里运行 |
| 其他 | 每接入一个新 agent 只需要一个运行器和一组夹具；v1 之后欢迎贡献 |

## 路线图

| 里程碑 | 结束时能做什么 | 状态 |
|--------|----------------|------|
| M0 技术验证 | — | **已完成**（[验证结论](docs/m0-findings.md)） |
| M1 任务引擎 | 在命令行里派任务（`topside run "…"`），每个任务在自己的 worktree 里 | **已完成** |
| M2 岛与派活 | 快捷键 → 输入 → 任务出现在岛上 | 下一个 |
| M3 需要你的时刻 | 在岛上批准权限、回答问题 | |
| M4 结果与验收 | 结果卡片、diff、追加指令、开 PR、合入、丢弃 | 第一个可以日常使用的版本 |
| M5 配方 | 实现并验证、先计划、实现并复查 | |
| M6 开源准备 | 贡献者文档、运行器接入指南 | |
| M7 打磨与 v0.1.0 | 设置、引导、历史、首次发布 | |

详情见[开发计划](docs/development-plan.md)。

## 现在能试什么

要求：macOS 14 或更高，Xcode 16 或更高（Swift 6）。

### 用命令行运行任务引擎

需要已经装好并登录 Claude Code 或 Codex（至少一个）。

```bash
git clone https://github.com/wzhang68/Topside.git
cd Topside
swift build -c release
alias topside="$PWD/.build/release/topside"

topside doctor                 # 检查 git、Claude Code、Codex
topside serve                  # 在单独的终端里运行引擎
```

在另一个终端里，进入任意一个 git 仓库：

```bash
topside run "给 calc.py 加一个 multiply(a, b) 函数" --wait
topside run "为解析器写测试" --agent codex
topside list                   # 所有任务，最紧急的在前
topside logs <id> --follow     # agent 正在做什么
topside show <id>              # 结果：改了哪些文件、花费、如何在终端里接管
topside discard <id>           # 删除 worktree 和分支
```

每个任务都在 `~/.topside/worktrees` 下自己的 worktree 里、在 `topside/…` 分支上运行，不会碰你的工作目录。停掉 `topside serve` 后 agent 会继续运行，重新启动时自动接上。在 M3 之前，agent 需要你批准的操作一律被拒绝，结果里会写明被拒了几次。如果仓库在新的 worktree 里需要未跟踪的文件或准备步骤：`topside repo --copy .env --prep "npm ci"`。

### 岛的窗口原型

用的是假数据，不涉及 agent：

```bash
swift run --package-path Spikes/m0-window
```

主屏幕顶部正中会出现一个黑色胶囊（有刘海的屏幕上会包住刘海）。鼠标悬停会展开。按 **⌥ Space**（Option + 空格）打开派活输入框，回车或 Esc 关闭，焦点回到原来的应用。在展开态里点“退出”，或在终端按 Ctrl-C 退出。

`Spikes/` 里的其他验证代码会在一次性仓库里驱动真实的 Claude Code 和 Codex，每次花费不到一美分，用法见各文件开头的说明。

## 仓库结构

```
Sources/
  TopsideCore/          数据模型和任务状态机（不出现 agent 的名字）
  TopsideEngine/        进程、worktree、持久化、调度
  TopsideRunners/       Claude Code 和 Codex 的命令行与事件解析
  TopsideIPC/           命令行和引擎之间的 Unix socket
  topside/              命令行工具
Tests/                  单元测试和集成测试；Fixtures/ 是录下的真实 agent 运行
docs/
  design.md             设计文档
  development-plan.md   里程碑和任务
  m0-findings.md        验证结论
Spikes/                 M0 的一次性验证代码，不是产品代码
  m0-permissions/       权限 hook、恢复会话、中断
  m0-detach/            独立于应用运行的 agent 进程
  m0-worktree/          隔离的 worktree 流程
  m0-window/            岛的窗口原型
Tests/Fixtures/         真实 agent 运行的脱敏录制，用于解析器测试
scripts/
  scrub-fixtures.py     把原始录制处理成可以提交的夹具
  check-no-private-data.sh
  fake-agent.sh         回放夹具，测试从不调用模型
```

`swift test` 会运行全部测试，不调用任何模型。

## 参与贡献

项目还很早期，现在最有用的是：

- **对设计的反馈。** 如果想法或安全模型里有你觉得不对的地方，欢迎开 issue。
- **其他 agent 版本的夹具。** 用 `Spikes/m0-permissions/` 里的脚本录制各个场景，用 `scripts/scrub-fixtures.py` 脱敏，提 PR 前运行 `scripts/check-no-private-data.sh`。不要提交原始录制。

## 许可证

[MIT](LICENSE)

## 致谢

把刘海用作 agent 状态栏的想法来自 [claude-island](https://github.com/farouqaldori/claude-island) 和 [CodeIsland](https://github.com/wxtsky/CodeIsland) 等项目。
