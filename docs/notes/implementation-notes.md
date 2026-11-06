# 实现笔记

README 只留结论；这里放被它请出来的细节：设计 token、找 dsh 的三处坑、菜单栏动效的实测数字、文稿文件夹的三层，以及失败状态对照。

## 设计 token

面板不是 dashboard，而是一块仪器面板：单色，唯一的颜色是「正在变化」（琥珀）和「出错了」（砖红）；状态词用等宽字放大到 24–30pt，让整块面板读起来像一张终端打印纸；整块面板只有一个凹陷面（读数带），其余全是「印」在板子上的；分隔是 1px 深线 + 1px 亮线，模仿刻在金属上的线；圆环 + 圆点与 DSH 启动页的细环 spinner 同构，菜单栏图标用同一个环、靠**形状**区分状态（中文界面里也不依赖颜色）。

| 角色 | 浅色 | 深色 |
|---|---|---|
| 面板底 | `#FBFBFA` | `#16181B` |
| 凹槽 | `#EFEFEC` | `#0A0C0E` |
| 墨（主文字 / 主按钮） | `#0F1115` | `#F2F3F4` |
| 次级文字 | `#61666B` | `#B9BEC4` |
| 三级文字 | `#6F7378` | `#8F959B` |
| 过渡（琥珀） | `#A8641A` | `#E0A44A` |
| 失败（砖红） | `#B02A1E` | `#F2705F` |

字体全部用系统字体（等宽 = SF Mono，界面 = SF Pro，中文回落 PingFang），不打包任何字体文件：字体被替换后静默变样的代价比「不够独特」更贵。

## 找到 dsh，并让它的 node 也找得到

GUI 应用的 PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，里面既没有 `node` 也没有 nvm；而 `dsh` 是 `#!/usr/bin/env node` 脚本，从这种环境里跑会直接失败（`env: node: No such file or directory`）。三个点必须一起做对：

1. **问交互式登录 shell。** `zsh -lic 'printf <marker>; command env -0'` 才会读 `~/.zshrc`，而 nvm / miniforge / 代理导出一般只写在那里；`zsh -lc` 只读 `.zshenv` / `.zprofile`，拿到的 PATH 里没有 node——这正是「点开 app 起不来」的原因。marker 之后的内容才解析，所以 `.zshrc` 的欢迎语和提示符转义污染不了第一个变量。`-lic` 没有 node 时再试 `-lc`，两者都没有才退回进程环境（每次 resolve 在日志里留一行 `spawn env: … PATH head … node …`）。
2. **把 dsh 自己的目录放到 PATH 最前面。** `node` 就在 `…/node/v24.22.2/bin/dsh` 旁边；前置这个目录既保证找得到 node，也保证用的是装 dsh 时那个版本，而不是 nvm default alias 指向的另一个。
3. **找不到 node 就别装作在启动。** spawn 之前读一次可执行文件第一行：确实 `#!/usr/bin/env node` 而 PATH 里没有 node，就不发子进程，直接报「找不到 node → 检查 ~/.zshrc 里的 nvm 导出」，而不是让面板显示一个 `退出码 127`。

配套的两条：**检测不等 shell**（`redetect` 只用缓存或进程环境，面板第一帧不会被一次 1.5 秒的 shell 启动卡住；真正 spawn 前才阻塞等环境，那时面板已经写着「正在启动…」）；**只认那一行**（就绪信号是 `dsh web: <url>` 且带单个 `token` 参数，stderr 里的插件崩溃与 `DSH_MOBILE_NETWORK_*` 警告只进日志）。

日志：`~/Library/Logs/dsh bar/dsh-web.log`，每次启动写分隔头，每行带 `[out]` / `[err]`，超过 1 MB 轮转为 `.1`；面板上的「打开日志」打开的就是它。

## 失败状态对照

| 现象 | 面板 |
|---|---|
| 30 秒没打印地址 | `启动失败` + 超时诊断，进程被终止 |
| stderr 出现 `EADDRINUSE` | `端口 N 已被占用。` + 换一个空闲端口 |
| 退出码非 0 | `dsh 在启动时退出了（退出码 N）。` |
| 就绪后崩溃 | 同上，并记下「上次运行 刚刚」 |
| 找不到或不可执行 | `找不到或无法执行 dsh。` + 选择可执行文件 |
| 工作目录 / `DSH_HOME` 不可用 | 面板点名那条路径 + 「改回默认」 |

端口 0：失败时按「换一个空闲端口」把端口设成 0，`dsh --port 0` 由系统分配，真实端口从 URL 回读并写回设置。

## 菜单栏动效

| 时机 | 动效 |
|---|---|
| 启动中 | 缺口环顺时针旋转，1.1 秒一圈 |
| 停止中 | 同一个环反向旋转，1.4 秒一圈 |
| 刚刚就绪 | 中心圆点膨胀再收回，一次 0.4 秒（8 帧换图，然后接力到呼吸） |
| 正在监听 | 中心圆点呼吸：1.0 ↔ 1.26，单程 1.3 秒，一直呼吸 |

唯一常驻的动效是监听时的呼吸，因为它说明「还活着」而不是「在变化」。打开系统「减少动态效果」后不再有任何运动，静态图形本身已经能区分状态。

踩过的坑：

1. **别用按钮自己的 layer。** AppKit 给 view 的 backing layer 用 `(0, 0)` 锚点，而 `transform.rotation.z` 绕锚点转：旋转直接加到按钮图层上，图标会绕着按钮左下角甩出菜单栏；把锚点改成中心又会被下一次 layout 冲掉。所以过渡态插入一个自建的 `CALayer`（锚点天然在中心），里面是一张预先烘焙好的 2x 位图纹理（缺口环，半径 5.2、线宽 1.6、265°），颜色按当前菜单栏外观取黑或白——模板图的自动着色搬到图层上就没有了。
2. **不逐帧换图。** 20fps 替换 18pt 图标实测吃 15% CPU（每次赋值都要让状态栏重新排版）；改成 Core Animation 动同一个图层后降到 1% 左右，由 WindowServer 合成，主线程零轮询。
3. **动效层不要用 `CAShapeLayer`。** 第一版把旋转和呼吸画在矢量图层上，合成器每帧重新栅格化路径，app 峰值吃到 14% CPU。现在只吃 2x 位图纹理：旋转是纹理变换、缩放是纹理采样，都不重绘，再用 `preferredFrameRateRange` 把呼吸限到 12fps、旋转限到 15fps，实测 app CPU 0.1–0.5%。
4. **别拿 WindowServer 当指标。** 动画期间 WindowServer 看着很高（43–48%），但 A/B/A 对照（无 app / 有呼吸 / 杀掉之后）三次读数一致——那是机器上的其它负载。核对请看 `ps -p $(pgrep DshBar) -o %cpu=`。

## 文稿文件夹

dsh 的默认工作区在 `~/Documents/deepseek-harness`，而 macOS 把它当受保护目录：没被授权的进程 `opendir` 直接拿 `EPERM`，系统再弹一句「想访问你的文稿文件夹」。dsh 是 dsh bar 的子进程，TCC 把这次访问算在 dsh bar 头上，所以弹窗写的是 dsh bar，而且每启动一次就来一次。两个原因叠在一起：**TCC 按代码身份记授权**（ad-hoc 签名每次重编译 cdhash 都变，系统看到的是「一个从没见过的新 app」），以及**不授权就起不来**（dsh 只抛 `EPERM`，看上去像别的地方坏了）。

三层各管一件事：

| 层 | 做什么 |
|---|---|
| 点「启动」时才问 | 按下启动而文件夹还没有书签时，才用 `NSOpenPanel` 预选 `~/Documents` 让你点一次「授权…」。启动 app、常驻菜单栏、打开设置都不弹任何对话框——用户的选择本身就是系统认的 user intent |
| 记住它 | 选择存成 security-scoped bookmark（`UserDefaults` 的 `documentsFolderBookmark`），每次启动 resolve + `startAccessingSecurityScopedResource()`，spawn 子进程之前再取一次 |
| 不盲读 | 启动时**不**探测文件夹（探测本身就会触发系统弹窗），状态显示「未请求」；只有已存书签或点了「重新检查」才真的读一次 |

`build-app.sh` 会优先用登录钥匙串里的 Code Signing 证书（`DSHBAR_SIGN_IDENTITY` 指定，或自动取第一个），没有才退回 ad-hoc，并把 cdhash 打出来——换证书前后对比一下就知道系统认的是不是同一个 app。签名稳不住时它同时也是「文稿文件夹每次都问」和「开机自启不可用」两个问题的根因。

| 状态词 | 含义 |
|---|---|
| `未请求`（琥珀） | 还没问过，也没读过 |
| `已授权 · 12 项` | 现在读得动，数字是目录项数 |
| `未授权`（砖红） | 系统记着拒绝，或读被拒 |
| `文件夹不存在` | 路径不在，或被 `DSHBAR_DOCUMENTS_FOLDER` 指到了别处 |

复位与调试：

```sh
tccutil reset SystemPolicyDocumentsFolder dev.dsh.bar     # 清掉系统授权，重新看那一次询问
defaults delete dev.dsh.bar documentsFolderBookmark       # 只删书签（下次点「启动」会重新问）
DSHBAR_DOCUMENTS_FOLDER=/tmp/somewhere ...                # 换目标文件夹，看「未请求 / 未授权」两种状态
```

询问只有一个触发点：在面板上按「启动」（失败状态的「重试」和「换一个空闲端口」走同一条路）。设置里的「授权…」可以随时补授权，不必等到下次启动。

## 防止休眠的三条硬事实

1. **`-i` 是唯一被允许的开关。** `-d` 会连屏幕一起点亮，`-u` 声明用户活跃（同样重置显示器计时器），`-s` 只在电源适配器下有效而范围更宽，`-m` 管的是磁盘。四条不使用写进 `Caffeinate.forbiddenFlags`，`dshbar-check` 逐条断言不出现。
2. **`-w <pid>` 是安全阀。** dsh 一退，caffeinate 自己退；app 被 `kill -9` 也只残留到 dsh 退出为止。
3. **不断言外部实例。** 终端里起的 dsh 没有本进程的 pid 锚点（`lsof` 出来的 pid 可能被复用），语义上也不该由这次 app 改变电源行为。

`pmset -g assertions` 是一手证据：caffeinate 只产生 `PreventUserIdleSystemSleep`，命名 `caffeinate command-line tool`，并带一行 `Created for PID: <dsh pid>`；`SleepAssertion.parse` 就是按这段真实输出写的，smoke 会在真机上再读一次。
