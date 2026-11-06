# 第五轮规划：token 卫生 + 启动参数 → 0.6.0

> 立项时间：2026-11-06 · 基线 commit `c12ffde`（0.5.0 + README 瘦身）
> 基线证据：`swift build` 通过；`swift run dshbar-check` → **544 checks passed**；工作树干净。
> 前四轮：**M1** 外观与仪器面板；**M2** 真机控制；**M3** 打磨（工作区 / `DSH_HOME`、环境、退出策略与交接、单实例、快捷键、登录项）；**M4** 防休眠。
> 这一轮不是新面板，是两块**正确性**：把已经存在的 token 从三处持久化位置拿掉（P0），把 `dsh web` 剩下的 flag 变成可配置、可校验的 argv（P1）。

---

## 0. 判据

1. `~/Library/Logs/dsh bar/dsh-web.log` 里不再出现任何 token 值；0.5.0 写下的旧文件（以及 `.1`）在首次启动时被就地打码，且重复启动不再改写（幂等）。
2. 面板的日志四行、磁盘日志、`dshBarHandoff` 记录三处显示/存储的都是 `token=…`；真实 URL 只活在内存里，直到用户按「打开网页界面」或「复制链接」。
3. 「复制链接」默认仍给可用地址（带 token）；右键菜单另有一项「复制不含凭证的链接」，产物去掉 `token` 查询项、保留其它参数。
4. 设置 › 启动页的五组字段留空时，spawn 的 argv 与 0.5.0 **逐字相同**：`--profile P --no-open [--port N]`。
5. 填了就先校验再 spawn：通配地址（`0.0.0.0` / `::` / `*`）、主机名、单边 TLS、缺失的证书/私钥/patch、空 patch 路径，都在 `posix_spawn` 之前变成 `启动失败` + 一行点名诊断。
6. `--host` 让 `PortProbe` 跟着绑定地址走：探测任意本机 IPv4/IPv6 字面量，而不是永远 127.0.0.1。
7. 绑定到非 loopback 时页脚出现 `局域网`（同时开 TLS 则 `局域网 · TLS`），且页脚仍然一行放下 port / profile / 防休眠 / 网络词 / 退出。
8. 每个新枚举/字段都有中英双语文案断言；`dshbar-check` ≥ 640；`swift run dshbar-smoke --port 3099 --flags` 全绿。
9. 不主动 commit / push / tag。

## 1. P0 · token 卫生

**问题**：dsh 把启动 URL 连 token 一起打印（`dsh web: http://127.0.0.1:3080/?token=…`），而这个 token 就是 `/api` 的 bearer。0.5.0 把它写进了三处：

| 位置 | 生命周期 | 0.5.0 的行为 |
|---|---|---|
| `~/Library/Logs/dsh bar/dsh-web.log` | 跨运行，1 MB 轮转 | 整行原样落盘；实测 278 KB 里有 25 个 token |
| 面板 `Output` 四行 | 本次运行 | 原样显示（截图即泄露） |
| `dshBarHandoff`（UserDefaults） | 跨运行 | `launchURL` 带 token 存进 plist |

**做法**：

- `DshBarKit/Live/LogRedaction.swift`（新）：一个显式字符集的扫描器，不是正则。值字符集是 `[A-Za-z0-9-._~+/=%]`，所以 `(…?token=abc).` 的右括号不会被吞掉；`mytoken=` 前面是字母，不算 key；`TOKEN=` 大小写不敏感；对已打码的行幂等。`redactedURL` 就是 `redact`（用 `URLComponents` 重建会把 `…` 编码成 `%E2%80%A6`，比原值更丑）；`urlWithoutToken` 才用 `URLComponents`，因为要真的删掉查询项。
- **一个打码点**：`LiveBackend.append(line:stream:)` 打码后再喂给 `LogBuffer` 和 `LogFileWriter`；`LogFileWriter` 自己再打一次（幂等）作为第二道。`LaunchOutput.classify` 用的是打码前的原始行，token 不丢功能。
- **存量清理**：`LogFileWriter.init` 调 `scrubExistingTokens()`，读 `dsh-web.log` 和 `dsh-web.log.1`，变了才原子重写。实测 25 → 0。
- **交接记录**：打码放在 `HandoffStore.save` 而不是调用点——这条记录的唯一读者是「下次启动」，它从不读 URL，所以谁写都该是打码的。
- **复制分级**：`HarnessModel.copyLink(redacted:)`；面板按钮维持带 token（那才是能打开的链接），右键菜单两项并排，`copyLinkHelp` 在按钮上说明差别。

## 2. P1 · 启动参数

`dsh web --help` 的八个参数里，0.5.0 用了两个。新增五组，全部可选：

| 字段 | flag | 规则 |
|---|---|---|
| 绑定地址 | `--host` | 具体 IPv4/IPv6 字面量（`inet_pton` 判定）；`0.0.0.0` / `::` / `*` 拒绝；主机名拒绝 |
| 公开地址 | `--public-url` | `URLComponents` + scheme ∈ {http, https} + 非空 host |
| 信任主机 | `--trusted-host`（可重复） | `host` 或 `host:port`，`[::1]:8080` 允许；带 scheme / 路径 / 空白拒绝 |
| TLS | `--tls-cert` / `--tls-key` | 必须成对；文件必须存在 |
| 附加 patch | `--patch`（可重复） | 非空且文件存在 |

**结构**：

- `DshBarKit/Live/WebLaunchFlags.swift`（新）：一个值类型，`arguments(profile:port:noOpen:)` 是唯一拼 argv 的地方；`problems(fileExists:)` 把「文件存在吗」注入进来，决策表因此可以在没有文件系统的机器上断言。类型名不是 `LaunchFlags`——`AppKit` 经 HIServices 带进来一个同名 `typedef UInt16 LaunchFlags`，在 app target 里会歧义。
- `BarPreferences` 加六个字段 + 归一化（`normalizeHost` / `normalizeTrustedHosts` / `normalizeFilePath` / `normalizePaths`），以及 `launchFlags` / `setLaunchFlags` 两个方向的桥。
- `LiveBackend.spawn`：先 `firstProblem()`，再 `arguments(...)`；`launchedFlags` 记住这次真正发出去的 flag，`emit()` 用它画页脚与读数带——运行中改设置不会让面板声称一个进程并不在的地址。
- `PortProbe`：改成 `getaddrinfo(AI_NUMERICHOST)` + 一个 `sockaddr_storage`，IPv4/IPv6 一套代码；`localhost` / 空串归一成 `127.0.0.1`；非字面量返回 `free`（「不是我能判断的」）。
- 设置新增第五页 `启动`（`network` 图标）：五个字段 + 逐行红字 + 文件选择器 + patch 列表；失焦一次提交，和路径字段同一套规矩。
- 面板页脚：`Copy.networkBadge(lan:tls:)` 合成一个词；页脚间距 14 → 10，否则 `profile web` 会被截成 `profile…`。

## 3. 实施结果

| 工作流 | 落地内容 | 证据 |
|---|---|---|
| W1 脱敏 | `LogRedaction` + 三处接入 + 存量清理 + 复制分级 + 右键菜单 | 真日志 25 → 0；`dshbar-check` 断言 16 条 |
| W2 flag 值层 | `WebLaunchFlags`（argv / 校验 / loopback / 通配）+ 偏好字段与归一化 | 决策表与 argv 逐条断言 |
| W3 接线 | spawn 校验、`launchedFlags`、`PortProbe` 任意本机地址、`emit` 的 bindHost/secure | `dshbar-smoke --flags` 全绿 |
| W4 UI | 设置 › 启动页、页脚网络词、诊断 `启动参数不可用` | `panel-lan-tls-*.png` |
| W5 断言 | 544 → **654** 条（脱敏 / flag / 偏好 / 快照 / 文案 / 探针） | `swift run dshbar-check` |
| W6 收尾 | 0.6.0、README、本文件、实现笔记 | `Resources/Info.plist` |

真机 smoke（`--flags`）的关键几行：

```
· argv: --profile web --no-open --port 3099 --host 127.0.0.1 --trusted-host 127.0.0.1:3099
✓ the bind flag reaches the argv
✓ the trusted-host flag reaches the argv
✓ the port flag survives next to them
✓ the printed URL follows the bind address (127.0.0.1)
✓ the token URL is accepted (303)
✓ the server exited after SIGTERM
✓ port 3099 is free again
```

## 4. 与原计划的偏差

1. **`LaunchFlags` → `WebLaunchFlags`**。原计划没预料到 `AppKit` 的 `LaunchFlags` typedef；第一次全量 build 直接歧义报错。改名比在每个文件里写 `DshBarKit.LaunchFlags` 便宜。
2. **`redactedURL` 不做 URL 重建**。第一版用 `URLComponents` 把值换成 `…`，结果落盘/落断言的是 `token=%E2%80%A6`。改回纯文本扫描后，日志里就是 `token=…`。
3. **网络词合成一个**。原计划页脚加两个词（`局域网`、`TLS`），实测 348 pt 放不下，`profile web` 被截断。合成 `局域网 · TLS` 并收窄间距后一行放下。
4. **复制分级放在右键菜单**，不是面板加第二个按钮。面板的「复制链接」是唯一需要 token 的地方（打开网页界面），再加一个并列按钮会把「复制」这件事变成选择题。
5. **`--tls-*` 不做端口指纹**。TLS 打开后 `PortProbe` 的明文 GET 拿到的是 TLS 记录而不是 401，因此外部实例只能被判成「端口被占用」，不能「接管」。这一点写进设置说明，不假装支持。
6. **`--from-default-profile` 没做**。它是破坏性的（会用模板覆盖自定义 profile），放在一个「顺手改两个 flag」的页面里语义不对；留给将来的 profile 浏览页。

## 5. 边界（记录在案）

- **TLS 与外部实例互斥**：见偏差 5。`--host` 绑到局域网时，探针跟的是绑定地址；绑到 TLS 时只能判「有人」。
- **`--public-url` 不改探测地址**：探针永远打绑定地址，不打公开地址（那可能是反代或公网名）。
- **旧日志只清一次内容，不改权限**：文件仍是 `0644`；打码解决的是「值还在」，不是「谁能读」。
- **`token=…` 是替换而不是删除**：日志仍能看出「这里曾有一个 token」，这对排查「为什么浏览器未授权」有用。
- **面板那四行仍是内存里的明文？** 不是：`append` 之前就换了。`launchURL` 本身在内存里是明文，这是「打开网页界面」需要的，退出即消失。

## 6. 下一轮

**通知与守护**（崩溃/端口被占/插件报错 → 系统通知；指数退避重启；诊断包 zip），然后回到 **M4 多实例**：`PortProbe` 已经能探任意本机地址，`WebLaunchFlags` 已经是值类型，多实例只差「一组 pid」的 `SleepGuard` 和一张列表。
