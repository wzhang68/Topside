# M0 验证结论

> 2026-11-15 · 对应开发计划 M0
> 测试环境：macOS 15.6，Claude Code 2.1.325，Codex 0.169.0
> 所有测试都在 scratchpad 里的一次性 git 仓库中进行，提示词都是合成的测试指令。脱敏后的录制在 `Tests/Fixtures/`，场景说明见那里的 README。
> 测试脚本：`Spikes/m0-permissions/`、`Spikes/m0-detach/`、`Spikes/m0-worktree/`、`Spikes/m0-window/`

## 总结

| 结论 | 状态 | 一句话 |
|------|------|--------|
| 1. 事件流 | 完成 | 两种 agent 的事件流都够用，但都有需要特别处理的地方 |
| 2. 权限 | Claude Code 完成；Codex 等你操作 | Claude Code 的 hook 方案可行，可等待至少 30 分钟；Codex 卡在 hook 信任上，只靠沙箱的备选方案已验证可行 |
| 3. 进程管理 | 完成 | 脱离运行、重新接上、中断都可行 |
| 4. 窗口 | 显示完成；交互等你检查 | 层级 25 的不激活面板能画在菜单栏上 |
| 5. 对照产品 | 等你试用 | — |
| 另：worktree | 完成 | 流程可行；未跟踪文件必须复制；构建缓存不能直接克隆 |

## 结论 1：事件流

### Claude Code（`-p --output-format stream-json --verbose`）

- 每行一个 JSON 对象，`type` 有 `system`、`assistant`、`user`、`result`、`rate_limit_event`。
- `system` 的子类型：`init`、`hook_started`、`hook_response`、`permission_denied`、`thinking_tokens`，以及后台任务相关的 `task_started`、`task_progress`、`task_updated`、`task_notification`、`background_tasks_changed`。
- **`result` 里直接有结果卡片需要的数据**：`total_cost_usd`、`permission_denials`、`subagent_stats`、`terminal_reason`、`num_turns`。

**需要特别处理的三点：**

1. **一次运行可能有多个 `result`。** 子 agent 默认在后台运行：主 agent 先结束一轮并输出第一个 `result`（“子 agent 还在跑”），子 agent 完成后主 agent 自动再跑一轮，输出第二个 `result`。**判断一步是否完成，要看进程是否退出，不能看第一个 `result`。**
2. **被中断的运行，从输出看可能和成功完成一模一样。** 测试中 Claude Code 的前台 `sleep 40` 被它自己的执行环境拦下，它改为后台运行，随即以一个**成功的** `result` 结束了这一轮，然后在等待后台任务时收到 SIGINT，退出码 0（SIGTERM 时是 143）。单看事件流和退出码无法判断“被中断”，所以中断由 Topside 自己记录：信号是它发的，它就知道。（更正：本文档最初写的是“被 SIGINT 中断时没有 `result`”，那是看漏了前面的事件，M1 写解析测试时发现。）
3. **费用上限不是硬上限。** `--max-budget-usd 0.0005` 时实际花了 0.003 美元：限额在两次模型调用之间检查，会超出一次调用的量。超限时 `result` 的子类型是 `error_max_budget_usd`，退出码 1。

子 agent 的事件里有 `subagent_type`、`description`、进度和状态，足够在岛上画出子 agent 树（设计文档第 12 节的后续方向）。

### Codex（`exec --json`）

- 每行一个 JSON 对象：`thread.started`（含 `thread_id`）、`turn.started`、`item.started`、`item.completed`、`turn.completed`（含 `usage`）。
- `item` 的类型有 `command_execution`（含 `command`、`status`、`exit_code`、`aggregated_output`）、`agent_message`、`error`。
- **没有费用**，只有 token 数。`review` 的 `turn.completed` 里 token 数全是 0。
- 被 SIGINT 中断时退出码 1，最后一个事件是没有完成的 `command_execution`。

**需要特别处理的一点：`--json` 里看不到所有工具调用。** Codex 有时不直接调用 shell，而是用一个叫 `exec` 的脚本工具（写一段 JavaScript，在里面调用 `exec_command`）。这类调用**不出现在 `--json` 的事件流里**，只记录在 Codex 自己的会话文件 `~/.codex/sessions/YYYY/MM/DD/rollout-*-<thread_id>.jsonl` 中。

对设计的影响：只读 `--json` 的话，岛上“当前在做什么”对 Codex 会不完整。可选做法：同时读会话文件（内部格式，没有稳定性承诺）；或者接受不完整，只显示 `--json` 里有的。M1 先只读 `--json`，在界面上不假装知道更多。

## 结论 2：权限

### Claude Code：hook 方案，已验证可行

启动时用 `--settings <文件>` 注入 `PermissionRequest` hook，不修改 `~/.claude/settings.json`。

| 场景 | 结果 |
|------|------|
| hook 不表态 | 拒绝，事件流出现 `permission_denied` |
| hook 允许 | 执行 |
| hook 拒绝并给出理由 | 拒绝，理由原样传给 agent |
| hook 等待 150 秒后允许（超时设为 600 秒） | Claude Code 一直等待，之后执行 |
| hook 等待 30 分钟后允许（超时设为 2400 秒） | Claude Code 等了 1800 秒，之后执行（2026-11-16 完成） |
| hook 超时（超时 20 秒，hook 45 秒才结束） | hook 被取消，拒绝 |
| 被拒绝后，恢复会话并告知“用户已批准” | 重新执行了那条命令（“允许并继续”路径成立） |

- 应答格式：`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`，拒绝时 `behavior` 为 `deny` 并带 `message`。
- **所有异常情况都是拒绝**，符合设计文档 8.4 的“默认拒绝”。
- 不采用 `--permission-prompts host`：它要求宿主一直持有 agent 的管道，和进程脱离的方案冲突。

### Codex：hook 需要信任；只靠沙箱的备选方案可行

**hook 路径（等你操作）：**

- 用 `-c 'hooks.<事件>=[...]'` 按次注入的 hook 能被识别，但没有运行。Codex 只运行信任过的 hook，信任按 hook 内容的哈希记录（据官方文档）。
- `PermissionRequest` 的应答格式与 Claude Code 完全相同，`topside-hook` 可以共用输出代码。
- `--dangerously-bypass-hook-trust` 会让所有未信任的 hook 一起运行，包括仓库自带的，产品不能用。用它做的验证测试被 Claude Code 的安全检查拦截，没有运行。
- 下一步：你用 `Spikes/m0-permissions/trust-codex-hooks.sh` 在交互式 Codex 里信任一次，我再验证信任后 `exec` 能否审批、换仓库和 worktree 后信任是否仍然有效。

**只靠沙箱（已验证）：**

- 不装 hook，`-s workspace-write`，让 Codex 往工作区和临时目录之外写文件：**默认审批策略和 `on-request` 两种情况下都直接失败**（Operation not permitted），既没有发起审批，也没有被自动审核器放行。
- 所以这个备选方案是安全的：越界操作一律失败，agent 会在回复里报告。缺点是 Topside 拿不到结构化的“被阻止”事件，只能从 agent 的回复里看到。
- 注意：`workspace-write` 默认允许写临时目录。

## 结论 3：进程管理，已验证可行

| 检查项 | 结果 |
|--------|------|
| 启动器返回耗时 | 0 秒，agent 的父进程变为 1 |
| 模拟应用中途退出 | agent 继续运行 |
| 从全新进程重新接上 | 用 pid 加进程启动时间确认身份，从保存的偏移量继续读；16 行事件不丢不重 |
| SIGINT / SIGTERM | Claude Code 0.4 秒内退出，Codex 0.9 秒内退出 |
| 子进程清理 | 中断后 agent 启动的 shell 命令都被一起结束，没有孤儿进程 |
| 追加指令 | Claude Code `--resume` 和 Codex `exec resume` 都保持原会话 id，agent 记得之前的内容 |

不需要 `claude --bg`。

## 结论 4：窗口（部分）

原型：`Spikes/m0-window/`，运行 `swift run --package-path Spikes/m0-window`。

已确认（外接显示器，2560×1440pt，无刘海）：

- 无边框、不激活的 `NSPanel`，层级 25（`.statusBar`），能画在菜单栏之上。收起态盖在菜单栏正中，展开态向下延伸，截图确认。
- 屏幕识别正确：无刘海，菜单栏高 25pt。
- `⌥Space` 用 Carbon 的 `RegisterEventHotKey` 注册成功，不需要辅助功能权限。

需要你手动检查：

| # | 检查 | 怎么做 | 期望 |
|---|------|--------|------|
| 1 | 悬停展开 | 鼠标移到胶囊上 | 约 0.15 秒后展开，移开约 0.3 秒后收起 |
| 2 | 点击穿透 | 点击胶囊旁边透明区域下面的窗口 | 点击落到下面的窗口上 |
| 3 | 派活输入框 | 在任意应用里按 `⌥Space`，输入几个字，按回车 | 能直接打字；回车后收起，焦点回到原来的应用 |
| 4 | 取消 | 再次 `⌥Space`，按 Esc | 同上 |
| 5 | 全屏应用 | 把某个应用切到全屏 | 岛仍然可见 |
| 6 | 切换桌面 | 切到另一个 Space | 岛仍然可见，位置不变 |
| 7 | 内建刘海屏 | 把内建屏设为主屏 | 胶囊包住刘海，左右两侧显示内容 |
| 8 | 插拔显示器 | 运行中插拔外接显示器 | 岛自动移到新的主屏顶部 |

## worktree 流程，已验证可行

脚本：`Spikes/m0-worktree/worktree_flow.py`。在一个现造的 Node 项目和 Topside 仓库自身的克隆副本上测试。

| 步骤 | 结果 |
|------|------|
| 选择 git | PATH 里是 2.16.2，`/usr/bin/git` 是 2.50.1。按最低版本 2.25 选出后者 |
| 建 worktree 和分支 | 0.03 秒 |
| 不复制 `.env` | 测试失败：`node: .env: not found` |
| 复制 `.env` 后 | 测试通过 |
| 改动统计 | 用临时索引（`GIT_INDEX_FILE`）计算，得到 3 个文件，含未跟踪的新文件；普通 `git diff` 只有 2 个。worktree 真正的索引没有被动过 |
| PATH 里的 git 2.16 在新版 git 建的 worktree 里 | `status`、`log`、`diff` 都正常，所以 agent 用旧 git 没问题 |
| 清理 | worktree 目录和分支都删除；主工作目录的 HEAD、分支、状态完全没变 |
| 冷构建成本（Swift） | 新 worktree 里首次构建 8.7 秒，主工作目录热构建 1 秒 |
| 用 APFS 写时复制（`cp -c`）克隆 `.build` | 复制 0.5 秒，但构建失败（`missing required module 'SwiftShims'`）：SwiftPM 的缓存里写死了绝对路径 |

**对设计的影响：**

- Topside 必须自己选 git，不能用 PATH 里的。
- “要复制的文件”是必需的配置，不是可有可无。
- 改动统计用临时索引的方法。
- 构建缓存不能通用地克隆。可以作为每仓库的可选配置“要克隆的目录”，并注明只适用于路径无关的缓存（`node_modules` 很可能可以，未验证；SwiftPM 的 `.build` 不行）。

## 其他发现

- **你用的终端是 Ghostty**（录下的环境变量 `TERM_PROGRAM=ghostty`）。开放问题 Q3 的终端部分有了答案：“接管到终端”优先支持 Ghostty。编辑器还不知道。
- **Codex 的复查意见格式规整**：`[P1] 标题 — 文件:行号`，后跟说明。可以解析成优先级、文件、行号，在结果卡片上逐条显示。`codex exec review --base <分支>` 正好对应“任务分支对比基线分支”。复查时没有修改任何文件。
- 本轮所有测试的模型费用合计不到 0.05 美元。

## M0 剩余事项

| 任务 | 状态 |
|------|------|
| 1. 初始化仓库 | 完成 |
| 2. 试用 CodeIsland 和 Conductor | 需要你来做 |
| 3. Claude Code 事件流录制 | 完成 |
| 4. Codex 事件流录制 | 完成 |
| 5. 权限机制比较 | Claude Code 完成（含 30 分钟等待）；Codex 等你信任 hook |
| 6. 进程脱离与重新接上 | 完成 |
| 7. 窗口原型 | 显示确认；交互检查需要你做 |
| 8. worktree 流程 | 完成 |
| 9. 夹具脱敏脚本 | 完成：`scripts/scrub-fixtures.py`，检查脚本 `scripts/check-no-private-data.sh` |
