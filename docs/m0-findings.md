# M0 验证结论

> 2026-11-15 · 对应开发计划 M0
> 测试环境：macOS 15.6，Claude Code 2.1.325，Codex 0.169.0
> 所有测试都在 scratchpad 里的一次性 git 仓库中进行。原始录制没有进仓库（含本机路径），脱敏后的夹具留到 M1 处理。
> 测试脚本：`Spikes/m0-permissions/`、`Spikes/m0-detach/`

## 结论 2：权限

### Claude Code：采用 hook 方案，已验证可行

做法：启动时用 `--settings <文件>` 注入 `PermissionRequest` hook，不修改 `~/.claude/settings.json`。

| 场景 | hook 的行为 | 结果 |
|------|-------------|------|
| 不表态 | 退出 0，不输出 | 操作被拒绝，事件流里出现 `permission_denied` |
| 允许 | 输出 allow | 操作执行 |
| 拒绝 | 输出 deny 和理由 | 操作被拒绝，理由原样传给 agent |
| 等待 150 秒后允许（hook 超时设为 600 秒） | 阻塞 150 秒 | Claude Code 一直等待，之后正常执行 |
| hook 超时（超时设为 20 秒，hook 45 秒才结束） | 被取消 | 操作被拒绝 |

**结论：**

- 无终端模式（`-p`）下 `PermissionRequest` hook 会触发。
- 应答格式：`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`，拒绝时 `behavior` 为 `deny` 并带 `message`。
- **hook 可以长时间阻塞，时长由 hook 的 `timeout` 字段决定。** 已验证 150 秒。更长时间（例如 30 分钟）没有测，上限未知。
- **所有异常情况都是拒绝**：不表态、超时。这正是设计文档 8.4 要求的“默认拒绝”。
- 另有一个参数 `--permission-prompts host|none`，可以让宿主程序通过标准输入输出回答权限请求。它要求宿主一直持有 agent 的管道，与下面“进程脱离”的方案冲突，所以不采用。

### Codex：卡在 hook 信任上，未完成

- 用 `-c 'hooks.<事件>=[...]'` 按次注入的 hook 能被 Codex 识别（它会提示把 `SessionEnd` 的超时压到 3 秒），**但没有运行**。最可能的原因是没有被信任：Codex 只运行信任过的 hook，信任按 hook 内容的哈希记录。
- `--dangerously-bypass-hook-trust` 可以跳过信任，但它会让本次运行中**所有**未信任的 hook 一起运行，包括仓库自带的。对一个刚克隆的不可信仓库派活时，这等于执行仓库作者写的任意命令。**产品不能使用这个参数。**
- 用这个参数做的验证性测试被 Claude Code 的安全检查拦截，没有运行。
- 另一个发现：Codex 的 `workspace-write` 沙箱默认允许写临时目录。测试“写工作区以外的文件”时，目标必须放在临时目录之外。

**待定：Topside 的 Codex hook 怎样获得信任。** 候选方案：

1. 首次使用时，引导用户在 Codex 里用 `/hooks` 信任一次 Topside 的 hook。需要验证：按次注入的 hook 能否被信任，信任后对其他仓库、其他 worktree 是否继续有效。
2. 不用 hook，只靠 Codex 的沙箱：以 `workspace-write` 运行，需要提权的操作直接失败。Topside 显示“被沙箱阻止”，用户可以选择放宽这一步的沙箱后重跑。粒度粗，但不需要任何信任步骤。

## 结论 3：进程管理，已验证可行

做法：用 `setsid` 启动 agent，标准输入接 `/dev/null`，标准输出直接重定向到 `events.raw.jsonl`，启动器不等待子进程就退出。

| 检查项 | 结果 |
|--------|------|
| 启动器返回耗时 | 0 秒 |
| agent 进程的父进程 | 1（由系统接管，与启动器无关） |
| 模拟应用中途退出 | agent 继续运行 |
| 从全新的进程重新接上 | 用 pid 加进程启动时间确认身份，从保存的偏移量继续读 |
| 事件完整性 | 文件共 16 行，两次读取各 8 行，不丢不重，全部是合法 JSON |
| 结束检测 | 进程退出后正确识别，最后一条是 `result` |

**结论：** 设计文档 8.1 的方案成立，不需要 `claude --bg`。

## 结论 1：事件流（部分）

### Claude Code（`-p --output-format stream-json --verbose`）

- 每行一个 JSON 对象，`type` 有 `system`、`assistant`、`user`、`result`、`rate_limit_event`。
- `system` 的子类型里有 `init`、`hook_started`、`hook_response`、`permission_denied`、`task_started`、`task_notification`、`thinking_tokens`。
- **`result` 里直接有结果卡片需要的数据**：`total_cost_usd`、`permission_denials`（被拒绝的操作列表）、`subagent_stats`（子 agent 统计）、`terminal_reason`、`stop_reason`。
- 一次只调用一条 Bash 命令的小任务，haiku 模型的费用约 0.001 到 0.004 美元。

### Codex（`exec --json`）

- 每行一个 JSON 对象：`thread.started`（含 `thread_id`）、`turn.started`、`item.started`、`item.completed`、`turn.completed`（含 `usage`）。
- `item` 的类型有 `command_execution`（含 `command`、`status`、`exit_code`）、`agent_message`、`error`。
- `turn.completed` 只有 token 数，**没有费用**。

完整的字段清单和夹具在 M1 开始时整理。

## 结论 4：窗口（部分）

原型：`Spikes/m0-window/`，运行 `swift run --package-path Spikes/m0-window`。

已确认（外接显示器 XG32WCS，2560×1440pt，无刘海）：

- 无边框、不激活的 `NSPanel`，层级 25（`.statusBar`），可以画在菜单栏之上。收起态的胶囊盖在菜单栏正中，展开态向下延伸，截图确认显示正常。不需要更高的层级。
- 屏幕识别正确：无刘海，菜单栏高 25pt。
- 窗口固定为 660×300pt，内容在其中做动画，窗口本身不改变尺寸。
- `⌥Space` 全局快捷键用 Carbon 的 `RegisterEventHotKey` 注册成功，不需要辅助功能权限。

需要你手动检查：

| # | 检查 | 怎么做 | 期望 |
|---|------|--------|------|
| 1 | 悬停展开 | 鼠标移到胶囊上 | 约 0.15 秒后展开，移开约 0.3 秒后收起 |
| 2 | 点击穿透 | 点击胶囊旁边透明区域下面的窗口 | 点击落到下面的窗口上，不被拦截 |
| 3 | 派活输入框 | 在任意应用里按 `⌥Space`，输入几个字，按回车 | 输入框出现并能直接打字；回车后收起，焦点回到原来的应用，原应用里的光标位置不变 |
| 4 | 取消 | 再次 `⌥Space`，按 Esc | 同上 |
| 5 | 全屏应用 | 把某个应用切到全屏 | 岛仍然可见 |
| 6 | 切换桌面 | 切到另一个 Space | 岛仍然可见，位置不变 |
| 7 | 内建刘海屏 | 断开外接显示器，或在设置里把内建屏设为主屏 | 胶囊包住刘海，左右两侧显示内容 |
| 8 | 插拔显示器 | 运行中插拔外接显示器 | 岛自动移到新的主屏顶部 |

## 其他发现

### git 版本

本机 PATH 里排在前面的是 `/usr/local/bin/git`，版本 2.16.2（2018 年）。系统自带的 `/usr/bin/git` 是 2.50.1。2.16 没有 `git worktree remove`（2.17 才加入）。

**对设计的影响：** Topside 不能直接用 PATH 里的 `git`。启动时在候选路径（`/usr/bin/git`、`xcrun --find git`、PATH）中找到满足最低版本（暂定 2.25）的那个并固定使用。agent 在 worktree 里自己调用 git 时用的是 PATH 里的版本，这在 M1 的 worktree 测试里要覆盖到。

## M0 还剩的任务

| 任务 | 状态 |
|------|------|
| 1. 初始化仓库 | 完成 |
| 2. 试用 CodeIsland 和 Conductor | 未开始，需要你来试用 |
| 3. Claude Code 事件流录制 | 部分完成，缺子 agent、中断、超出费用上限的场景 |
| 4. Codex 事件流录制 | 部分完成，缺 `resume`、`review` |
| 5. 权限机制比较 | Claude Code 完成；Codex 卡在信任问题上 |
| 6. 进程脱离与重新接上 | 完成 |
| 7. 窗口原型 | 原型完成，显示已确认；交互检查需要你手动做 |
| 8. worktree 流程 | 未开始 |
| 9. 夹具脱敏脚本 | 未开始 |
