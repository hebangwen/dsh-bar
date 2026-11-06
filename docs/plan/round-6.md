# 第六轮规划：通知 + 崩溃守护 → 0.7.0

> 立项时间：2026-11-06 · 基线 commit `6424904`（0.6.0）
> 基线证据：`swift build` 通过；`swift run dshbar-check` → **654 checks passed**；`swift run dshbar-smoke --port 3099 --flags` 全绿；工作树干净。
> 前五轮：M1 面板、M2 真机控制、M3 打磨、M4 防休眠、M5 token 卫生 + 启动参数。
> 这一轮补的是**无人值守**：这个 app 常驻菜单栏，面板关着的时候发生的事，只有通知能说出来；而「服务崩了」是唯一能自己修的那一类。

---

## 0. 判据

1. 服务在「正在监听」时进程死掉（非主动停止），3 次预算内自动重启：间隔 1 / 2 / 4 秒，单次上限 8 秒。
2. 两次崩溃相隔超过 2 分钟，预算清零——「跑了一小时才崩一次」不该被惩罚。
3. 手动「启动」清零预算，并且能打断正在等待的重启。
4. 启动阶段就退出**不算**崩溃：那是 `启动失败`，不排程，不推「正在重启」。
5. 预算用完进入 `启动失败`，并推一条「已停止自动重启」；不再排程。
6. 外部实例（终端里起的）永远不进崩溃守护：没有 pid 锚点，重启它等于抢别人的进程。
7. 四个时刻各推一条系统通知：启动失败、崩溃、放弃重启、停止失败；**状态**不推，只有**转换**推——重新打开面板看到失败不会补推。
8. 通知权限只在用户打开「行为 › 通知」时向系统申请；被拒时那一行变红并给一个跳到系统通知设置的按钮。
9. 取消一个正在等待的重启 = 停下（`.stopped`），不是失败。
10. 每个新状态、每个新文案都有中英断言；`dshbar-check` ≥ 730；`swift run dshbar-smoke --port 3099 --watchdog` 全绿。
11. 不主动 commit / push / tag（除非用户要求）。

## 1. 行为规格

**崩溃 → 重启** 的状态形状：

```
.listening --exited--> .restarting(attempt n, delay d) --timer--> .starting --ready--> .listening
                        |                                          --exited--> .failed
                        --cancel--> .stopped      --start(手动)--> .starting
                        --预算耗尽--> .failed
```

| 事件 | 结果 |
|---|---|
| `.exited` while `.listening`，守护开，有 `retryTarget` | 进 `.restarting`，记一次 attempt，发 `.scheduleRestart(delay:)` |
| 同上但预算已满 | 直接 `.failed`，`gaveUpAfter = 3` |
| 同上但守护关 | 直接 `.failed`（0.6.0 行为） |
| `.exited` while `.starting` | `.failed`，不排程（启动失败，不是崩溃） |
| `.exited` while `.stopping` | `.stopped`（主动停止） |
| `.restartDue` | `.starting` + `.restartNow(port:)`，attempt 保留在读数带 |
| `.restartAbandoned`（守护关掉时） | `.failed` + `.cancelRestart` |
| `.cancel` while `.restarting` | `.stopped` + `.cancelRestart` |

## 2. 落地结构

| 文件 | 内容 |
|---|---|
| `DshBarKit/Live/CrashWatchdog.swift`（新） | `maxAttempts = 3`、`window = 120s`、`delay(attempt:)` 1/2/4/8、`decide(attempts:now:)` 纯函数 |
| `DshBarKit/Live/NotificationPolicy.swift`（新） | `NotificationEvent`、`event(previous:next:)` 决策表、`identifier(_:)`（同一类共用 id，replace 而不是堆叠） |
| `HarnessSnapshot.swift` | `HarnessPhase.restarting`、`restartAttempt`、`restartDelay`、`isRestarting` |
| `HarnessReducer.swift` | `RetryTarget` 值类型、`attempts/lastCrashAt/crashHandled/retrying/gaveUpAfter`、`.restartDue` / `.restartAbandoned`、`.scheduleRestart` / `.cancelRestart` / `.restartNow`；`reduce(..., autoRestart:)` |
| `BarPreferences.swift` | `autoRestart` / `notify`（默认都开）+ 两个 key |
| `LiveBackend.swift` | `restartTimer`、`.restartNow` 复用 `probePort` 那条路、`announce(previous:next:)` 决定要不要推 |
| `DshBar/NotificationCenterClient.swift`（新） | `CrashNotifier` 协议 + `UNUserNotificationCenter` 实现 + 代理（前台也显示 banner、点击开面板），非 bundle 进程整段隐藏 |
| `DshBar/HarnessModel.swift` | `notificationPermission` 发布、`update(autoRestart:)`、`update(notify:)`、`onRequestStart` |
| `DshBar/SettingsView.swift` | 行为页两个开关 + 权限 chip + 被拒时的跳转按钮 |
| `DshBar/AppDelegate.swift` | 打开设置时刷一次权限；点击通知 → 激活 app 并弹面板 |
| `DshBarCheck` | +79 条（544 → 654 → **736**）：退避表、窗口、决策表、状态转移、通知策略、文案、偏好 |
| `DshBarSmoke` | `--watchdog` / `--watchdog off`：真 dsh、`SIGKILL`、真端口 |

## 3. 实施结果

| 工作流 | 落地内容 | 证据 |
|---|---|---|
| W1 值层 | `CrashWatchdog` + `NotificationPolicy`，两个纯函数 | 断言逐条 |
| W2 状态机 | 新相位 + 三条命令；启动/停止/取消/超时都覆盖到 | 断言 + smoke |
| W3 接线 | 定时器、`announce`、`gaveUpAfter` 一次性消费 | smoke 全绿 |
| W4 UI | 行为页两行 + 权限 chip；面板 `正在重启…` + 说明 + 取消 | `panel-restarting-zhHans.png` |
| W5 断言 | 736 条 | `swift run dshbar-check` |
| W6 收尾 | 0.7.0、README、本文件 | `Resources/Info.plist` |

smoke 的实际输出：

```
· pid 95673 serving http://127.0.0.1:3099/?token=…
✓ the port answers as a dsh before the crash
✓ the server died from SIGKILL
✓ the crash enters restarting
✓ it is the first retry
✓ the first retry is scheduled one second out
✓ the crash is a notification, and it says it is being retried
✓ the timer starts the server again
✓ the port is free again after the SIGKILL
· pid 95705 restored http://127.0.0.1:3099/?token=…
✓ the restart lands back in listening
✓ a successful restart clears the attempt
✓ the restart keeps the port
✓ pressing stop is not a notification
✓ watchdog passed
```

## 4. 与原计划的偏差

1. **取消一个等待中的重启落在 `.stopped`，不是 `.failed`。** `.failed` 会摆一颗「重试」按钮和一个诊断块，可用户刚刚明确表示不想重试。
2. **`.restartDue` 复用 `probePort` → `spawn` 那条路**，而不是直接 spawn。端口在被杀与重启之间可能被别人占了，重新探一次只多 300 ms。
3. **`crashHandled` 标记。** 同一个崩溃可能连着到两条 `.exited`（信号 + 退出码），没有这个标记会重启两次、预算一次少两个。
4. **`retryTarget` 用结构体而不是元组。** 第一版是 `(port: Int, profile: String)?`，`HarnessState` 就不再 `Equatable`，reducer 里所有「没变化就原样返回」的判断全废。
5. **通知权限只在开关打开时申请。** 启动就弹权限框是菜单栏工具的坏习惯；用户打开开关那一刻才是他要的通知。
6. **`NotificationCenterClient` 用协议。** `UNUserNotificationCenter.current()` 在非 bundle 进程里直接抛异常，`dshbar-check` / `dshbar-smoke` 会当场崩，所以协议 + `isBundled` 封住整个面。
7. **`defaults.set(Bool?, forKey:)` 的陷阱。** 直接把 `Bool` 提升成 `Any?` 会存成整数，`as? Bool` 永远读回 nil，两个开关看起来「存了但没生效」。显式解包后存。

## 5. 边界（记录在案）

- **外部实例不守护**：终端里启动的 dsh 没有可核实的 pid 锚点，重启它会和那个终端抢所有权。
- **重启不跨 app 退出**：app 退出时定时器取消，下一次启动从 `.stopped` 开始。
- **「插件崩溃」不推通知**：stderr 里的 `DSH_MOBILE_*` 警告和 MCP 失败只进日志（面板已经用「强调行」标出来）。把它们当错误推，会让正常启动也响一次。
- **通知只在有 bundle 时真的落地**：`dshbar-check` / `dshbar-smoke` 里 `permission == .unavailable`，`posted` 只用来计数。
- **通知权限无法在脚本里授予**：真机验证需要人在系统设置里点一次。这一条和 round-4 §5 的 app 级联调限制同源。
- **1 秒的首个重试**：端口冲突的恢复窗口可能小于 dsh 释放端口的时间，第二次尝试会拿到 `端口被占用`，于是计入预算。三次预算对这种情形仍然够用。

## 6. 下一轮

**诊断包**（环境 + argv + `--dump-config` + 日志尾 + `pmset` 一个 zip），然后回到 **M4 多实例**：`SleepGuard` 从「盯一个 pid」变成「盯一组」，`HarnessSnapshot` 从单个变成列表。
