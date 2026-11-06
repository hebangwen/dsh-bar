# 第四轮规划：接入 `caffeinate` → 0.5.0

> 立项时间：2026-11-06 · 基线 commit `aa61204`（0.4.0）
> 基线证据：`swift build` 通过；`swift run dshbar-check` → **454 checks passed**；工作树干净。
> 前两轮：**第一轮 M1** 外观与仪器面板；**第二轮 M2** 真机控制；**第三轮 M3** 打磨（工作区 / `DSH_HOME`、环境诊断、退出策略与交接、单实例、快捷键、开机自启）。
> 第四轮只加一个功能：**服务在监听时持有一条 `caffeinate -i -w <dsh pid>` 断言，机器不进入待机休眠，屏幕仍按系统设置关闭。**

---

## 0. 判据

1. 服务进入「正在监听」且由 dsh bar 启动时，`pmset -g assertions` 出现一条 `PreventUserIdleSystemSleep`，且**不出现** `PreventUserIdleDisplaySleep`。
2. 断言绑在 dsh 的 pid 上（`-w`）：dsh 退出，caffeinate 自己退出，不依赖 app 轮询去杀。
3. 停止 / 退出 / 「保留运行」交接 / app 崩溃都不留孤儿断言；`kill -9` 时残留最长不超过 dsh 的寿命。
4. `caffeinate` 缺失或提前退出时**服务照常运行**，只有这一行如实说「不可用 / 已退出」，并落一行日志；不重试风暴。
5. 面板仍是唯一状态真相：断言真在生效时页脚出现 `防休眠` / `awake`，否则不出现。
6. 每个新枚举/状态都有中英双语文案断言；`dshbar-check` ≥ 505；`swift run dshbar-smoke --port 3099 --sleep` 全绿。
7. 不主动 commit / push / tag。

## 1. 行为规格

**断言存在 ⟺** `effectiveSleepPolicy == .whileListening` **且** `phase == .listening` **且** `owner == .dshBar` **且** 有子进程 pid。

| 状态 | 断言 |
|---|---|
| `.listening` + `.dshBar` | 持有 `caffeinate -i -w <pid>` |
| `.listening` + `.external`（终端启动 / 交接实例） | 不持有 |
| `.starting` / `.stopping` / `.stopped` / `.failed` / `.unavailable` | 不持有 |

- 只 `-i`：`-d` 会阻止显示器休眠、`-u` 声明用户活跃（同样重置显示器计时器）、`-s` 只对电源适配器有效、`-m` 与磁盘有关。这四条不用的理由写进 `Caffeinate.forbiddenFlags`，由断言逐条检查。
- 停止即释放（进入 `.stopping` 就 release），不留「它已经不该被断言了但还挂着」的窗口。
- **合盖仍然会休眠**。断言只覆盖空闲休眠；`pmset disablesleep` 与显示器休眠设置 app 一律不碰。

## 2. 落地结构

| 文件 | 内容 |
|---|---|
| `DshBarKit/Live/SleepPolicy.swift`（新） | 两档策略（`off` / `whileListening`，默认后者）、`isEnabled`、中英 label、`DSHBAR_SLEEP_POLICY` 解析 |
| `DshBarKit/Live/Caffeinate.swift`（新） | 命令构造（`-i -w <pid>`）、可用性判断、`pmset -g assertions` 解析器 `SleepAssertion.parse` / `.caffeinateAssertions` |
| `DshBarKit/Live/SleepGuard.swift`（新） | `SleepGuardStatus`（idle / asserting(pid) / unavailable / failed）、纯决策 `SleepGuardPlan.plan`、`SleepGuardTarget.watchedPID`（哪个 pid 可以被盯）、`SleepGuard`（Foundation `Process` + `terminationHandler`） |
| `BarPreferences.swift` | `sleepPolicy` + `Key.sleepPolicy`，`load/save` 往返 |
| `HarnessSnapshot.swift` | `awake: Bool`（面板画的是事实，不是偏好） |
| `HarnessModel.swift` | `sleepStatus` 发布、`update(sleepPolicy:)`、协议新增 `sleepStatus` / `onSleepStatus` |
| `LiveBackend.swift` | 持有 guard，`emit()` 里 `syncSleepGuard()`；`shutdown()` / `prepareHandoff()` 释放；日志落 `sleep guard:` 行 |
| `DemoBackend.swift` | 同一条规则，供 demo 与出图 |
| `Copy.swift` | `sleepField` / `awakeBadge` / `sleepNote` / `sleepState(_:)` / `sleepToolMissing` |
| `SettingsView.swift` | 行为页新增「防止休眠」行 + 状态 chip + 说明 |
| `PanelView.swift` | 页脚 `防休眠` / `awake` |
| `StatusItemController.swift` | 右键菜单可勾选项 |
| `DshBarCheck/main.swift` | +90 条断言（454 → 544） |
| `DshBarSmoke/main.swift` | `--sleep` / `--sleep off`：真机验证断言出现与自释放 |
| `Resources/Info.plist` | 0.5.0 / build 5 |

## 3. 实施结果

| 工作流 | 落地内容 | 证据 |
|---|---|---|
| W1 Kit | 三个新文件 + 偏好字段；决策全部是纯值类型 | `dshbar-check` 全绿（本轮收尾 544 条） |
| W2 接线 | `emit()` → `syncSleepGuard()` → `reconcile`；快照 `awake` 取自 guard 的当前状态 | 真机 smoke 通过 |
| W3 UI | 设置行为页、页脚徽标、右键菜单、`Copy` 中英 | `sheet-settings-behavior-{zhHans,en}.png` |
| W4 断言 | 544 条：策略 / 命令 / 解析 / 决策表 / 哪个 pid 可被盯 / 退出裁决 / 偏好 / 文案 / fixture | `swift run dshbar-check` → 544 |
| W5 真机 | `dshbar-smoke --port 3099 --sleep` | 见下 |
| W6 收尾 | 版本 0.5.0、README、本文件、行为页图 | `sheet-settings-behavior-{zhHans,en}.png` |

smoke 的实际输出（关键几行）：

```
✓ a disabled policy holds no assertion
✓ a disabled policy leaves nothing in pmset
✓ the guard reports an assertion for pid 58699
  · sleep: sleep guard: /usr/bin/caffeinate -i -w 58699 (asserting)
✓ pmset lists exactly one caffeinate assertion for the dsh pid
✓ the assertion prevents idle system sleep
✓ the assertion leaves display sleep alone, so the screen can still turn off
✓ the assertion names the dsh pid
✓ the server exited after SIGTERM
  · sleep: sleep guard stopped with the dsh process (0), watched pid 58699
✓ the guard stops asserting once the dsh pid is gone
✓ caffeinate exited by itself; nothing is left in pmset
```

## 4. 与原计划的偏差

1. **默认值是 `whileListening`（开启）**，违反 0.4.0 立下的「升级不改行为」规矩。理由：这就是本轮要的功能；它被服务生命周期限制住，页脚可见，右键两下就能关。这条偏差只此一处，其它新字段仍遵守旧规则。
2. **不管外部实例**。终端里起的 dsh 没有本进程的 pid，断言也就没有可信的锚点（`lsof` 出来的 pid 可能被复用）。语义上也说得通：不是这次 app 在跑的服务，就不该由它改变电源行为。
3. **`Process` 而不是复用 `ChildProcess`**。后者是为「长命 dsh + 逐行输出」写的，给静默单行工具多开两个 pipe 和一对 dispatch source 没有收益；`terminationHandler` 正好回答唯一关心的问题——「断言是不是自己没的」。
4. **`release()` 会清掉 `.failed` / `.unavailable`**。第一版只在 `.asserting` 时发布 `.idle`，结果一次干净的停止之后，设置里仍挂着一条「已退出」的红字，等于让工具替用户按的停按钮背锅。
5. **「随 dsh 一起结束」回到 `.idle`，不算失败**。第一版把这个结局记成 `.failed`，于是 dsh 崩一次、或者干脆正常停止之后，设置里都挂着一句「已退出」，等于让工具替 dsh 的结局背锅。现在只有「dsh 还活着而 caffeinate 没了」才是 `.failed`；这条判定抽成了纯函数 `SleepGuardExit`，正反两向都有断言。
6. **`SleepGuardTarget.watchedPID` 单独抽出来**。原计划里这段判断写在 `LiveBackend` 的 6 行表达式里，测试碰不到；抽成纯函数后「哪些状态可以被盯」变成 6 条断言。

## 5. 观察到但未验证的部分

**app 级联调在本会话里做不到**，与第三轮记录的环境问题同源：这套后台 shell 里直接启动 `build/dsh bar.app` 时，`SingleInstance` 判定让进程立刻退（`DSHBAR_ALLOW_SECOND_INSTANCE=1` 才起来），而起来之后读不到子进程 stdout，面板停在「正在启动…」，永远到不了 `.listening`，guard 自然也不会 arm；`open "build/dsh bar.app"` 在本会话里不产生进程。所以：

- **已验证**：guard ↔ caffeinate ↔ `pmset` ↔ dsh 生命周期（smoke，真 dsh、真端口），决策表与「哪个 pid 可被盯」（check），设置页与面板的视觉（`ImageRenderer` 出图）。
- **待真机确认**（Aqua 会话里点一次「启动」）：页脚出现 `防休眠`；设置里显示 `正在防止休眠 · pid N`；退出 app 后 `pmset -g assertions | grep caffeinate` 为空；「保留运行」退出后同样为空。

```sh
swift build && swift run dshbar-check && swift run dshbar-smoke --port 3099 --sleep
pmset -g assertions | grep -i caffeinate
defaults write dev.dsh.bar dshSleepPolicy -string off   # 关掉后再看一次
```

## 5.1 追加：README 瘦身

0.5.0 提交之后把 README 从 333 行压到 111 行：只留「它是什么 / 状态表 / 能做什么 / 两个入口 / 命令 / 结构 / 下一步」，实现细节整体搬到 `docs/notes/implementation-notes.md`（设计 token、找 dsh 的三处坑、失败对照、菜单栏动效实测、文稿文件夹三层、防休眠三条硬事实）。round-3 文档里提到的「README 新增第三轮小节」因此不再单独存在——那是当时的记录，保持原样不改写。

## 6. 边界（记录在案）

- **合盖仍然会睡**。要连合盖都不睡只能 `sudo pmset -a disablesleep 1`，那是系统级设置，不属于这个 app。
- **`kill -9` 之后可能短暂残留**：caffeinate 是 app 的子进程，app 被强杀时它成为孤儿，但 `-w <dsh pid>` 让它的寿命不长于 dsh；dsh 一退，断言必消失。
- **双实例调试钩子**会产生两条断言（各自随进程退出释放），无害。
- **电池**：真·不休眠的笔记本装包里会掉电、发热。所以页脚有这个字，右键能关，README 第一句就写明它只阻止待机休眠。

## 7. 下一轮

仍是 **M4 多实例**（多 profile / 多端口并存 + 日志面板 + 导出诊断）。本轮的 `SleepGuard` 是单实例形状的；多实例时它需要按 pid 集合持有断言——那正是 `SleepGuardTarget` 抽成纯函数的另一个原因。
