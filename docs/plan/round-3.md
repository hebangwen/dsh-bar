# 第三轮规划：M3 打磨 → 0.4.0

> 立项时间：2026-11-05 · 基线 commit `df553e3`（tag `v0.3.0` = `dd38471`）
> 基线证据：`swift build` 通过；`swift run dshbar-check` → **297 checks passed**；Swift 源码 7,573 行。
> 前两轮：**第一轮 M1** 外观与仪器面板（单色 token、等宽状态词、态势灯、中英双语）；**第二轮 M2** 真机控制（定位 dsh、抓交互 shell 环境、指纹探端口、解析启动 URL、进程组停止、接管终端实例、`~/Documents` 授权）。第三轮不加新面板，只把"能跑"打磨成"可以每天用"。

---

## 0. 第三轮的判据

一轮做完，必须同时满足：

1. 用户在**不打开设置**的情况下，能靠默认值把一个会话跑起来（默认工作区、默认 `DSH_HOME`、默认退出行为都合理）。
2. 每一个"为什么起不来"都能在界面上说清楚，并在设置里有一条**可执行的修正动作**，而不是只在日志里留一行。
3. 面板仍是唯一的状态真相：新增的偏好不得让面板显示与真实进程不一致的状态。
4. `dshbar-check` 断言数 ≥ **380**（当前 297），每新增一个状态枚举/失败类型必须同时有中英文案断言。
5. 每个工作流收尾时在 **3099** 端口做一次真机 smoke，`3080` 上正在跑的会话不碰。

---

## 1. W1 · 工作区与 `DSH_HOME`

**现状**
- `BarPreferences`（`Sources/DshBarKit/Live/BarPreferences.swift:8`）只存 `binaryPath / port / profile` 三项。
- `ChildProcess.init` 已经支持 `workingDirectory`（`Sources/DshBarKit/Live/ChildProcess.swift:40`，走 `posix_spawn_file_actions_addchdir_np`），但 `LiveBackend.spawn`（`Sources/DshBar/LiveBackend.swift:315`）不传 —— 现成的挂点没用上。
- `DSH_HOME` 目前完全由登录 shell 环境透传；`LoginShellEnvironment.sanitize` 故意保留它（`Sources/DshBarKit/Live/LoginShellEnvironment.swift:59`），所以覆盖它必须显式写在 spawn 的 env 里，而不是删掉。

**目标**
- 设置里两个新字段：
  - **工作目录**：默认留空 = 不传 `chdir`，让 dsh 用自己在 `~/Documents/deepseek-harness` 下挑的默认工作区（`DocumentsAccess.defaultWorkspaceURL` 只作为占位文案）。
  - **DSH_HOME**：默认「跟随登录 shell」；可选「覆盖」，留空 = `~/.dsh`。
- 路径一律 `~` 展开、`standardizedFileURL` 归一；相对路径**拒绝**（GUI app 的 cwd 是 `/`，相对路径没有意义）。
- 目录不存在/不是目录：**启动前 fail fast**，面板进 `failed`，新增 `HarnessFailure.Kind.workspaceMissing` / `.dshHomeMissing`，中英文案各一条，第二按钮给「改回默认」。

**实现要点**
1. `BarPreferences` 增 `workspacePath: String?`、`dshHome: String?`、`dshHomeMode: DshHomeMode { followShell, override }`；`Key` 同步；`load/save` 兼容旧 defaults（缺 key → 旧行为）。
2. 新值类型 `LaunchTarget`（cwd + 覆盖的 env 键值）由 `BarPreferences` 计算，`ChildProcess` 只收结果，保持 `DshBarKit` 可测。
3. `LiveBackend.spawn`：`workingDirectory: target.cwd`，并在 `values` 上叠加 `DSH_HOME`；日志各留一行 `cwd: …`、`DSH_HOME: …（来源）`。
4. 工作目录落在 `~/Documents` 下时，仍先走现有 `owesDocumentsGrant` 流程（`Sources/DshBar/AppDelegate.swift:140`），不新增第二次授权弹窗。

**验收**
- 新断言：归一化 / `~` 展开 / 相对路径拒绝 / 存在性判定 / 两个新 failure kind 的中英文案 / 旧 defaults 兼容（≥ 28 条）。
- smoke：`DSHBAR_AUTOSTART=1` + 临时 workspace（`/tmp/dshbar-ws`）+ `DSH_HOME=/tmp/dshbar-home`，日志首两行含实际 cwd 与 `DSH_HOME`，服务器在 3099 起来后再停。

---

## 2. W2 · 环境重读

**现状**
- `LiveBackend` 缓存 shell 环境 60 秒（`Sources/DshBar/LiveBackend.swift:474`），解析结论只写日志（`:302` `spawn env: … PATH head … node …`）。
- 设置里没有任何入口告诉用户"当前环境来自哪、node 是哪个、为什么没找到"。

**目标**
- 设置新增「环境」区块，常显四个值：**来源**（交互 shell / 登录 shell / 进程环境）、**PATH 前三段**、**node 路径 + 版本**、**解析耗时 + 上次时间**。
- 「重新读取」按钮：强制冷解析，解析完立即刷新这四行；失败时把 README 里那段 `~/.zshrc` / nvm 诊断原样搬到界面上，而不是让用户去翻日志。

**实现要点**
1. 新值类型 `EnvironmentReport`（`source / pathHead / nodePath / nodeVersion / durationMs / resolvedAt / failureNote`），纯函数从 `[String: String]` + 耗时构造，便于断言。
2. `LiveBackend` 增 `environmentReport` 与 `rereadEnvironment()`：清缓存 → 主线程外解析 → 回投 `@Published`；`node --version` 用一次 `/bin/sh -lc 'command -v node && node -v'` 只读调用，不做网络/安装动作。
3. 解析失败不影响已在运行的实例（只更新报告与提示行）。

**验收**
- 断言：`EnvironmentReport` 构造与格式化、PATH 截断、node 缺失分支、`loginShell` 降级的提示文案中英（≥ 18 条）。
- 快照：`docs/design/sheet-settings-general-{en,zhHans}.png`（沿用 `DSHBAR_SNAPSHOT_SETTINGS` 出图；仓库只留通用/工作区两页，避免重复图）。
- smoke：故意 `PATH=/usr/bin:/bin` 启动一次，设置里显示"没有 node"且与日志一致。

---

## 3. W3 · 退出策略与孤儿交接

**现状**
- `AppDelegate.applicationWillTerminate`（`Sources/DshBar/AppDelegate.swift:89`）无条件 `model.shutdown()`，即「退出必停」。想留着服务器的人只能从终端起 dsh（走 external 分支）。
- external 分支的识别、接管、停止已经完整（`PortProbe` 指纹 + `ExternalInstance`），可以直接复用。

**目标**
- 三档 `quitBehavior`：**停止服务器（默认）** / **保持运行** / **每次询问**（带「记住我的选择」）。
- 保持运行时写一条**交接记录** `{pid, port, startedAt, launchURL}` 到 `UserDefaults`；下次启动校验「pid 还活着 + 端口指纹仍是 dsh + pid 的进程组属于 dsh」→ 通过则作为 external 实例展示，并在按钮下注明「上次由 dsh bar 启动」，提供 接管 / 停止。校验失败即丢弃记录，绝不按记录去杀进程。

**实现要点**
1. `BarPreferences.quitBehavior`；`AppDelegate` 分派：`stop` → 现有 `shutdown()`；`keep` → `model.prepareHandoff()`（不 `killpg`，只释放日志句柄）；`ask` → `NSAlert`（"退出并停止 / 退出但保留"，checkbox 写入 prefs）。
2. 新值类型 `HandoffRecord: Codable`，`LiveBackend` 启动时 `verifyHandoff()`；`ExternalInstance` 增加 `.ownHandoff` 标记，只影响文案，不影响动作。
3. 停止路径不变：仍然是 `killpg(SIGTERM)` → 5 秒 → `SIGKILL`。

**验收**
- 断言：`HandoffRecord` 编解码 / pid 失效 / 指纹不符 / 端口被别的 dsh 占用的三种丢弃分支 / `.ownHandoff` 文案中英（≥ 22 条）。
- smoke：`DSHBAR_QUIT_BEHAVIOR=keep` 启动 → 退出 app → `lsof -i :3099` 仍在 → 重新打开 app 显示「上次由 dsh bar 启动」→ 接管成功。

---

## 4. W4 · 单实例与全局快捷键

**现状**
- 无单实例保护：二次 `open` 会起第二个 `LSUIElement` 进程，菜单栏出现两枚图标，两个进程都可能去 spawn 同一个端口。
- 无全局快捷键。

**目标**
- 第二次 open：不起新进程，直接让已存在实例弹出面板（`NSRunningApplication` 找同 bundle id + 一次轻量 IPC 通知，`CFMessagePort` 或 `DistributedNotificationCenter`，失败则 `activate`）。
- 全局快捷键：默认 `⌥⌘D` 唤起面板，可在设置里关闭或改成 `⌃⌥D`；用 Carbon `RegisterEventHotKey`（不需要辅助功能授权）；注册失败（被占用）时显示"已被其它应用占用"，并保持关闭而不是静默失效。

**实现要点**
1. `SingleInstance`（`Sources/DshBarKit/Live/`）：`NSDistributedLock` 兜底 + bundle id 检测；`main.swift` 在建 `AppDelegate` 前判定。
2. `HotKeyCenter`：`EventHotKeyID` 与偏好字符串互转（纯函数，可断言），Carbon 绑定在 `StatusItemController` 旁，不污染 SwiftUI。
3. 设置里新增一行「快捷键」：`⌥⌘D` / `⌃⌥D` / 关闭，冲突时红字 + 行内诊断。

**验收**
- 断言：热键描述符解析与默认值、禁用路径、冲突文案中英、单实例判定（锁被占 / 无锁）（≥ 16 条）。
- 手工脚本：连续 `open "build/dsh bar.app"` 两次，菜单栏只有一枚图标，面板被拉起。

---

## 5. W5 · 开机自启（`SMAppService`）

**现状**
- 无自启。`scripts/build-app.sh` 在拿不到稳定签名时用 ad-hoc（会换 cdhash，`.app` 的身份每次构建都变）。

**目标**
- 设置里一个开关，走 `SMAppService.mainApp`，三态显示：**已开启** / **等待用户批准**（`requiresApproval`，给"打开系统设置 › 登录项"深链 `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`）/ **未开启**；失败给原因（未在 `/Applications`、签名不稳定等）。
- README 与构建脚本明确写清：自启与 `~/Documents` 授权都要求**稳定签名**（`DSHBAR_SIGN_IDENTITY`）。

**实现要点**
1. `LaunchAtLogin`（`Sources/DshBarKit/Live/`）：`status: .enabled/.requiresApproval/.notRegistered/.unavailable(reason)` 的纯映射层 + 一个薄 `SMAppService` 适配，映射层可被 check 直接调用。
2. 设置里开关只调这一层；状态每次打开设置都 `refresh()`，不缓存成"假开启"。

**验收**
- 断言：状态映射、每个状态的按钮可用性、深链字符串、错误文案中英（≥ 12 条）。
- 手工：开启 → `launchctl print gui/$UID | grep dsh` 能看到登录项 → 关闭后消失。

---

## 6. W6 · 收尾与发布 0.4.0

- 版本：`Resources/Info.plist` → `0.4.0` / `CFBundleVersion 4`。
- 文档：README「下一步」改为 M4（多实例/多 profile、日志面板、诊断导出），新增「第三轮：打磨」小节，链回本文。
- 断言总数目标 ≥ 380；`swift run dshbar-smoke` 全绿；`scripts/build-app.sh` 能产出 `build/dsh bar.app`。
- 打 tag `v0.4.0` **需用户明确同意**（本仓库规则：不主动 commit / push / tag）。

---

## 7. 顺序、依赖与写入范围

| 序 | 工作流 | 依赖 | 主要写入范围 |
|---|---|---|---|
| 1 | W1 工作区与 `DSH_HOME` | — | `Sources/DshBarKit/Live/BarPreferences.swift`、`Sources/DshBar/LiveBackend.swift`、`Sources/DshBar/SettingsView.swift`、`Sources/DshBarKit/Localization/Copy.swift`、`Sources/DshBarCheck/main.swift` |
| 2 | W2 环境重读 | W1 | `Sources/DshBarKit/Live/LoginShellEnvironment.swift`、`Sources/DshBar/LiveBackend.swift`、`Sources/DshBar/SettingsView.swift`、`Copy.swift`、`DshBarCheck/main.swift` |
| 3 | W3 退出策略 | W1 | `Sources/DshBar/AppDelegate.swift`、`Sources/DshBar/HarnessModel.swift`、`Sources/DshBarKit/Live/ExternalInstance.swift`、`BarPreferences.swift`、`Copy.swift`、`DshBarCheck/main.swift` |
| 4 | W4 单实例与热键 | W3 | `Sources/DshBar/main.swift`、`Sources/DshBar/AppDelegate.swift`、`Sources/DshBar/StatusItemController.swift`、`Sources/DshBarKit/Live/SingleInstance.swift`（新）、`Copy.swift` |
| 5 | W5 开机自启 | W3 | `Sources/DshBarKit/Live/LaunchAtLogin.swift`（新）、`Sources/DshBar/SettingsView.swift`、`scripts/build-app.sh`、`README.md` |
| 6 | W6 收尾 0.4.0 | 全部 | `Resources/Info.plist`、`README.md`、`docs/plan/round-3.md`、`Sources/DshBarCheck/main.swift` |

`LiveBackend.swift`、`SettingsView.swift`、`Copy.swift`、`DshBarCheck/main.swift` 被多个工作流触碰 —— **W1..W5 严格串行**，同一时间只有一个工作流在写。

---

## 8. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| ad-hoc 签名每次构建换 cdhash | `~/Documents` 授权、`SMAppService` 都失效 | 构建脚本已优先稳定签名；W5 把"签名不稳定"做成界面可诊断项 |
| 自启要求 app 在稳定位置 | 从 `build/` 直接跑，登录项指向临时路径 | 状态里识别路径并给出"移到 /Applications"提示 |
| 保留运行留下孤儿 dsh | 用户以为停了、端口仍被占 | 交接记录三重校验（pid / 指纹 / 进程组），失败只丢弃不杀 |
| Carbon 热键在新系统被占用 | 快捷键静默失效 | 注册返回值判定 + 界面红字，不假装开启 |
| 二次 open 起双实例 | 两枚菜单栏图标、端口争抢 | 单实例在 `main.swift` 最前置，早于任何 spawn |
| 新枚举漏文案 | 中英混排、面板显示英文 | 每个新 `Kind`/状态必须同时提交中英断言，否则该工作流不算完成 |

---

## 9. 本轮交付定义（DoD）

- 六个工作流全部合入 `main`，每次合入保持 `swift build` 与 `dshbar-check` 全绿。
- `dshbar-check` ≥ 380 条；smoke 覆盖「3099 起停 / keep-running 交接 / 无 node 诊断」三条真实路径。
- README 能让人从零跑到 0.4.0，第三轮计划文档留在 `docs/plan/round-3.md`。
- 面板在六个新状态下（工作区缺失、`DSH_HOME` 缺失、无 node、上次由我启动、快捷键占用、自启待批准）都有截图或快照，供设计复核。

---

## 10. 实施结果（0.4.0）

六个工作流已按下表落地，改动全部在本仓库内，未 commit / 未打 tag。

| 工作流 | 落地内容 | 验收证据 |
|---|---|---|
| W1 工作区与 `DSH_HOME` | `BarPreferences` 三个新字段 + `LaunchTarget`（`~` 展开、相对路径拒绝、存在性检查、`DSH_HOME` 覆盖与 `mkdir -p`）；`LiveBackend.spawn` 传 `workingDirectory` 与 overlay，失败进 `workspaceMissing` / `dshHomeMissing`，面板给「改回默认」 | 断言通过；日志 `launch paths: cwd … · DSH_HOME …` |
| W2 环境重读 | `EnvironmentReport`（来源 / PATH 前三段 / node / 耗时 / 降级说明）；`rereadEnvironment()` 绕过 60s 缓存；设置新增环境区块 | 断言通过；`sheet-settings-environment-{en,zhHans}.png` 中可见真实解析结果 |
| W3 退出策略与交接 | `QuitBehavior` 三档 + `HandoffRecord`/`HandoffStore`/`HandoffVerifier`（pid / 命令行 / 端口指纹三重校验）；`prepareHandoff()` 不 signal；`observedHandoff` 事件与「上次由 dsh bar 启动」文案 | 断言通过；`dshbar-smoke` 在真实 dsh 上得到 `.valid`，停止后同一记录不再可用 |
| W4 单实例与热键 | `SingleInstance` 裁决 + `DistributedNotification` 唤起 + `DSHBAR_ALLOW_SECOND_INSTANCE` 调试钩子；`HotKeyChoice` + Carbon `HotKeyCenter`，占用时只红字提示、不改写偏好 | 断言通过；设置页可见 ⌥⌘D / ⌃⌥D / 关闭 |
| W5 开机自启 | `LaunchItemStatus` 四态 + `SMAppService` 适配 + 稳定签名判断 + 登录项深链 | 断言通过；ad-hoc 构建下设置里如实显示「不可用」及原因（见 M3 设置页截图） |
| W6 收尾 | `Info.plist` 0.4.0 / build 4；README 第三轮章节；断言 297 → 433；`dshbar-snap` 新增 `failed-workspace`、`listening-handoff` 两场景 | `swift build`、`dshbar-check`（433）、`dshbar-smoke --port 3099` 全绿 |

### 与原计划的偏差

1. **工作目录的默认值**：原写「默认 `~/Documents/deepseek-harness/default-workspace`」，实施为「默认留空，交给 dsh」。理由：把默认写死成一条具体路径，会让默认工作区不存在的新机器在第一次启动时就 fail-fast，违背本轮判据第 1 条。该路径现在只出现在占位文案里。
2. **失败类型带路径**：`workspaceMissing` / `dshHomeMissing` 带关联值 `path`，诊断文案能直接引用用户填的那条路径；`HarnessFailure` 另加 `recovery`，面板第二颗按钮由它决定，而不是再由 view 判断 `port != nil`。
3. **热键注册器放在 app target**：`HotKeyCenter`（Carbon 绑定）留在 `Sources/DshBar/`，`DshBarKit` 只保留可断言的 `HotKeyChoice` / `HotKeyStatus`，避免 Kit 里出现第二个需要主线程的事件系统。
4. **单实例不引入 `NSDistributedLock`**：bundle id + 已有实例判定足够，锁文件会在崩溃后留下陈旧状态，反而要额外处理。调试钩子承担「故意跑第二份」的需求。
5. **设置窗口改成可滚动**：四组新行放不进原来 436pt 的固定高度，窗口 620pt + `ScrollView`；`ImageRenderer` 不布局 `ScrollView`，所以离屏快照走 `scrolls: false` 的全高渲染。

### 观察到但未解决的环境问题

在**这套无 GUI 会话的 shell 里**启动 `build/dsh bar.app` 并让它 spawn dsh 时，app 收不到子进程的任何一行输出（`DispatchSource` 读事件不触发），于是面板停在「正在启动…」，退出时也走不到「保留运行」分支（`ownsServer` 为假，安全地回落到停止）。同一条 `ChildProcess` 读路径在 `dshbar-smoke` 里工作正常，本机早前的 app 日志里也有过成功的 `[out] dsh web: …` 行；因此判定为运行环境（后台会话 + 已存在的 dsh 状态）导致，而非本轮改动。真机验收请按 README 的「跑起来」在 Aqua 会话里点一次「启动」确认。

### 追加：设置窗口重排（用户反馈）

初版把八组内容顺次排成一列，读起来散。改成与 macOS 偏好面板同构的四页签（通用 / 工作区 / 环境 / 行为）：顶部图标+文字页签，正文里标签右对齐成一列、控件紧随其后，说明文字只留一行并和控制列对齐。窗口 560×470（可滚动），`ImageRenderer` 逐页签出图。

副作用：`sheet-settings-folder-*.png` 与 `sheet-settings-m3-*.png` 两张旧图作废，替换为 `sheet-settings-{general,workspace,environment,behavior}-{en,zhHans}.png` 八张；`DSHBAR_SNAPSHOT_SETTINGS` 现在一次写出四张（基础名+页签名）。

### 已知边界（记录在案）

- **交接后子进程的 stdout 会被关掉。** app 退出，`ChildProcess` 的管道读端随之关闭；dsh 本身在读者消失后仍能正常服务（实测连收 4 个请求不写 stdout），但如果插件/MCP helper 在 spawn 之后才往继承来的 stdout 写东西，那条管道已经没了。spawn 之后无法改这一点，所以只记为边界，不在 README 里承诺「保留运行 = 一切如常」。
- **设置页快照是仿制的控件。** `ImageRenderer` 画不了 `TextField` 与 `.switch`，快照路径用同尺寸只读字段和自绘胶囊代替，图里看到的是值而不是可点控件。名字也是手工起的：`DSHBAR_SNAPSHOT_SETTINGS=/tmp/settings.png` 写出 `settings.png` + `settings-{workspace,environment,behavior}.png`，仓库里只保留通用/工作区两页的副本。
