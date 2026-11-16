# Checkpoint

> 更新：2026-11-16。新开 session 时先读这份文件，再按需读 `design.md`、`development-plan.md`、`m0-findings.md`。

## 当前进度

| 里程碑 | 状态 |
|--------|------|
| M0 技术验证 | 我能做的部分已完成。还有三件需要你来做（见“等你做的事”） |
| M1 任务引擎和命令行 | **完成**。完成标准和开发中修掉的问题见 `development-plan.md` 第 8 节 |
| M2 岛与派活 | 下一个 |

`topside` 命令行已经可以用：`swift build -c release`，然后 `topside serve` + `topside run "..."`。用法见 README。

## CI 的状态（新 session 第一件事）

**现象：** M1 推送后，GitHub Actions 的前两次运行卡在 `swift test` 步骤里超过 15 分钟（本地 6 秒）。

**根因（已在本地证实）：** `Command.run` 每运行一个短命令（git 等），就占住一个 GCD 线程，同步等另外两个 GCD 任务读完管道。并发命令一多（50 任务测试），GCD 的线程池（约 64 个）被占满，读管道的任务排不上队，整个进程死锁。CI 机器核数少，更容易触发。本地偶发的“35 秒才跑完、16 处失败”是同一个问题，当时靠 socket 客户端 30 秒超时才解开。新加的测试 `CommandTests.manyConcurrentCommandsComplete`（200 个并发命令）在旧代码上卡死超过 5 分钟，在新代码上 0.5 秒完成。

**修复（本次提交）：**

1. `Command.run` 改为不阻塞任何线程：输出写临时文件，完成靠进程结束回调。
2. socket 的阻塞读写改用独立线程，不占 GCD 线程池。
3. 另一个顺手发现的 bug：第二个 `topside serve` 启动失败时，会删掉第一个引擎的 socket 文件。已修，有测试。
4. CI：测试步骤 15 分钟超时、整个任务 30 分钟超时；同一分支的新推送会取消还在跑的旧运行；测试后把结果（未结束的测试、失败、日志最后几行）写成 GitHub 注释。

**新 session 要做的：** 确认 CI 变绿。日志下载需要仓库管理员权限，但注释不需要登录就能读：

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

如果 CI 仍然失败或卡住，注释会写出是哪个测试没有结束。

## 等你做的事

1. **窗口原型的手动检查**（影响 M2，最好在 M2 前做）：`swift run --package-path Spikes/m0-window`，按 `m0-findings.md` 第 4 节的 8 项检查。
2. **在 Codex 里信任 Topside 的 hook**（影响 M3）：命令见 `m0-findings.md` 结论 2。
3. **试用 CodeIsland 和 Conductor**（确认定位）。
4. **告诉我你常用的编辑器**（终端已知是 Ghostty）。

## 工作约定（这个项目里定下的）

- **提交和推送：** 用你的 git 身份（`wzhang68`），提交信息里**不加** Claude 的署名。只在你要求时提交和推送。推送前跑全量测试，**测试不过就停**，不推送。提交按内容拆分，每个提交单独能编译。
- **仓库是公开的：** 推送前运行 `scripts/check-no-private-data.sh --history`。原始录制不进仓库，夹具先用 `scripts/scrub-fixtures.py` 脱敏。
- **这台机器上 PATH 里有“遮蔽”：** `/usr/local/bin/git` 是 2018 年的 2.16（Topside 会自己选 `/usr/bin/git` 2.50）；`sample` 是 conda 的同名脚本，系统的在 `/usr/bin/sample`。手动命令里用完整路径。
- **测试：** `swift test`（约 4 秒，不调用模型）。性能测试默认跳过：`TOPSIDE_PERF=1 swift test --filter engineCPU`。
- **用真实 agent 做端到端测试时：** 设置 `TOPSIDE_HOME` 和 `TOPSIDE_WORKTREES` 指向临时目录，不要碰你真实的数据目录；用便宜模型（Claude `--model haiku --budget 0.10`，Codex `--model gpt-6-luna`）。
- **验证脚本里不用 `--dangerously-bypass-hook-trust`**（会被安全检查拦下，产品也不用）。

## 关键文件

| 文件 | 内容 |
|------|------|
| `docs/design.md` | 设计文档（v0.5） |
| `docs/development-plan.md` | 里程碑、M1 完成情况、M2 的任务清单 |
| `docs/m0-findings.md` | M0 验证结论，含窗口检查清单和 Codex 信任步骤 |
| `Sources/TopsideCore/TaskMachine.swift` | 任务状态机（纯函数） |
| `Sources/TopsideEngine/TaskEngine.swift` | 引擎 |
| `Sources/TopsideEngine/ProcessSupervisor.swift` | agent 进程的启动、脱离、跟读 |
| `Sources/TopsideRunners/` | Claude Code 和 Codex 的命令行与解析 |
| `Sources/topside/main.swift` | 命令行 |
| `Spikes/m0-window/` | 岛的窗口原型（M2 的起点） |
| `Tests/Fixtures/` | 脱敏后的真实 agent 事件流 |
