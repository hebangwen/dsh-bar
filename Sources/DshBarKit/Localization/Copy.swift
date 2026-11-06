import Foundation

/// The interface is bilingual; everything else (ports, URLs, log text) stays as
/// dsh printed it, in the monospaced face.
public enum UILanguage: String, Sendable, CaseIterable {
  case en
  case zhHans

  /// System language, with English as the fallback rather than the development
  /// machine's locale.
  public static func matching(preferred: [String] = Locale.preferredLanguages) -> UILanguage {
    for identifier in preferred {
      let lower = identifier.lowercased()
      if lower.hasPrefix("zh") { return .zhHans }
      if lower.hasPrefix("en") { return .en }
    }
    return .en
  }

  public var isCJK: Bool { self == .zhHans }
}

/// Every string the panel can render, in one place.
///
/// The copy is written to say what happened and what to do next — the app is a
/// utility someone opens dozens of times a day, so labels are verbs, not nouns.
public struct Copy: Sendable {
  public let language: UILanguage

  public init(language: UILanguage) {
    self.language = language
  }

  public static func system(_ preferred: [String] = Locale.preferredLanguages) -> Copy {
    Copy(language: .matching(preferred: preferred))
  }

  private func zh(_ hans: String, _ english: String) -> String {
    language == .zhHans ? hans : english
  }

  // MARK: - Chrome

  public var wordmark: String { "dsh bar" }

  public var output: String { zh("输出", "Output") }

  public var openLog: String { zh("打开日志", "Open log") }

  public var quit: String { zh("退出", "Quit") }

  public var settings: String { zh("设置", "Settings") }

  // MARK: - Settings tabs

  public var tabGeneral: String { zh("通用", "General") }

  public var tabWorkspace: String { zh("工作区", "Workspace") }

  public var tabEnvironment: String { zh("环境", "Environment") }

  public var tabBehavior: String { zh("行为", "Behavior") }

  public var tabLaunch: String { zh("启动", "Launch") }

  public var port: String { zh("端口", "port") }

  public var profile: String { "profile" }

  public func portLabel(_ port: Int) -> String {
    "\(self.port) \(port)"
  }

  public func profileLabel(_ profile: String) -> String {
    "\(self.profile) \(profile)"
  }

  // MARK: - State words

  public func stateWord(_ phase: HarnessPhase) -> String {
    switch phase {
    case .unavailable: return zh("未找到 dsh", "dsh not found")
    case .stopped: return zh("未运行", "Stopped")
    case .starting: return zh("正在启动…", "Starting…")
    case .listening: return zh("正在监听", "Listening")
    case .stopping: return zh("正在停止…", "Stopping…")
    case .failed: return zh("启动失败", "Couldn’t start")
    }
  }

  /// The line under the address: uptime, or the reason there is no uptime.
  public func readoutSide(_ snapshot: HarnessSnapshot) -> String? {
    switch snapshot.phase {
    case .unavailable:
      return zh("未检测", "not detected")
    case .stopped:
      return snapshot.lastRun.map { zh("上次运行 \($0)", "last run \($0)") }
        ?? zh("从未运行", "never run")
    case .starting:
      return zh("等待响应", "waiting for a response")
    case .stopping:
      return zh("正在关闭进程", "closing the process")
    case .listening:
      if snapshot.owner == .external {
        return snapshot.handoff ? handoffBadge : zh("由终端启动", "started in a terminal")
      }
      return snapshot.uptime.map { duration($0) }
    case .failed:
      return nil
    }
  }

  // MARK: - Actions

  public func primaryLabel(_ snapshot: HarnessSnapshot) -> String {
    switch snapshot.phase {
    case .unavailable: return zh("选择 dsh 可执行文件…", "Choose dsh executable…")
    case .stopped: return zh("启动", "Start")
    case .starting: return zh("正在启动…", "Starting…")
    case .stopping: return zh("正在停止…", "Stopping…")
    case .listening:
      return snapshot.owner == .external
        ? zh("在浏览器中打开", "Open in browser")
        : zh("打开网页界面", "Open web GUI")
    case .failed: return zh("重试", "Try again")
    }
  }

  public func secondaryLabel(_ snapshot: HarnessSnapshot) -> String? {
    switch snapshot.phase {
    case .listening:
      return confirmingStop ? zh("确认停止？", "Stop for sure?") : zh("停止", "Stop")
    case .starting:
      return zh("取消", "Cancel")
    case .failed:
      switch snapshot.failure?.recovery {
      case .freePort: return zh("换一个空闲端口", "Use a free port")
      case .defaultPaths: return zh("改回默认", "Use defaults")
      case nil: return zh("查看日志", "Show log")
      }
    case .stopped, .stopping, .unavailable:
      return nil
    }
  }

  /// Whether the next press of Stop should be an inline confirmation instead of
  /// a stop. Only externally owned servers need it: closing one kills a session
  /// the user opened somewhere else.
  public var confirmingStop: Bool { self.stopIsConfirming }

  private var stopIsConfirming = false

  public func withStopConfirmation(_ confirming: Bool) -> Copy {
    var copy = self
    copy.stopIsConfirming = confirming
    return copy
  }

  public var restart: String { zh("重新启动", "Restart") }

  // MARK: - Take over

  /// Converting a server someone started in a terminal into one this app owns.
  /// It has to stop the process first, so it is offered as an explicit action
  /// with its own confirmation, never as the default.
  public var takeOver: String { zh("接管", "Take over") }

  public var takeOverLabel: String {
    takeOverIsConfirming ? zh("确认接管？", "Take over?") : takeOver
  }

  private var takeOverIsConfirming = false

  public func withTakeOverConfirmation(_ confirming: Bool) -> Copy {
    var copy = self
    copy.takeOverIsConfirming = confirming
    return copy
  }

  public var takeOverNote: String {
    zh(
      "接管会先停掉这个进程，再由 dsh bar 重新启动；浏览器里正在进行的会话会中断。",
      "Taking over stops this server and restarts it under dsh bar. Sessions in progress in the browser will be interrupted."
    )
  }

  public var copyLink: String {
    copied ? zh("已复制", "Copied") : zh("复制链接", "Copy link")
  }

  /// Set for a moment after the launch URL was copied, so the action can
  /// confirm itself without a toast or a modal.
  public var copied: Bool { self.didCopy }

  private var didCopy = false

  public func withCopyConfirmation(_ didCopy: Bool) -> Copy {
    var copy = self
    copy.didCopy = didCopy
    return copy
  }

  public var cancel: String { zh("取消", "Cancel") }

  public var detectAgain: String { zh("重新检测", "Detect again") }

  public var chooseBinary: String { zh("选择 dsh 可执行文件…", "Choose dsh executable…") }

  // MARK: - Settings

  public var processSection: String { zh("进程", "Process") }

  public var appearanceSection: String { zh("外观", "Appearance") }

  public var binaryPath: String { zh("dsh 路径", "dsh path") }

  public var change: String { zh("更改…", "Change…") }

  public var portField: String { zh("端口", "Port") }

  public var profileField: String { "profile" }

  public var portAuto: String { zh("自动", "Auto") }

  public var portInvalid: String {
    zh("端口需要 1–65535，或用 0 让系统挑选。", "Port must be 1–65535, or 0 to let the system pick.")
  }

  public var notDetected: String { zh("未找到", "not found") }

  // MARK: - Workspace & DSH_HOME

  public var workspaceField: String { zh("工作目录", "Directory") }

  public var workspacePlaceholder: String {
    zh("dsh 默认", "dsh default")
  }

  public var dshHomeField: String { "DSH_HOME" }

  public var useDefault: String { zh("默认", "Default") }

  public var chooseLink: String { zh("选择…", "Choose…") }

  public var followShell: String { zh("跟随 shell", "From shell") }

  public var overrideShell: String { zh("指定", "Set") }

  public var workspaceChooseMessage: String {
    zh(
      "选择 dsh 启动时所在的工作目录（项目文件夹）。",
      "Choose the directory dsh starts in — the project folder."
    )
  }

  /// A relative path is not a typo worth guessing at: a GUI app's working directory
  /// is `/`, and dsh would inherit a directory the user never meant.
  public var reading: String { zh("读取中…", "reading…") }

  public func notAFolder(_ path: String) -> String {
    zh("不是文件夹：\(path)", "Not a folder: \(path)")
  }

  public func noSuchFolder(_ path: String) -> String {
    zh("文件夹不存在：\(path)", "No such folder: \(path)")
  }

  public var detectionMissing: String {
    zh(
      "在登录 shell 的 PATH、nvm、Homebrew 里都没找到。",
      "Not on the login shell PATH, in nvm, or in Homebrew."
    )
  }

  public var relativePathRejected: String {
    zh("相对路径不可用：GUI app 的当前目录是 /。", "A relative path can't work: a GUI app's directory is /.")
  }

  public var workspaceNote: String {
    zh(
      "留空 = dsh 自己的默认工作区（~/Documents/deepseek-harness）；填了会先检查，目录不存在就不启动。",
      "Empty means dsh's own workspace (~/Documents/deepseek-harness); a set folder is checked, and a missing one blocks the start."
    )
  }

  public var dshHomeNote: String {
    zh(
      "「跟随 shell」沿用登录 shell 的 DSH_HOME；「指定」留空等于 ~/.dsh。",
      "\"From shell\" keeps the login shell's DSH_HOME; \"Set\" with an empty field means ~/.dsh."
    )
  }

  // MARK: - Environment

  public var environmentSourceField: String { zh("来源", "Source") }

  public var environmentPathField: String { zh("PATH", "PATH") }

  public var environmentNodeField: String { "node" }

  public var environmentTimingField: String { zh("耗时", "Took") }

  public var reread: String { zh("重新读取", "Read again") }

  public func environmentSource(_ source: LoginShellEnvironment.Source) -> String {
    switch source {
    case .interactiveShell: return zh("交互式登录 shell", "interactive login shell")
    case .loginShell: return zh("登录 shell（未读 rc）", "login shell (no rc)")
    case .process: return zh("进程环境", "process environment")
    }
  }

  public var environmentFallbackNote: String {
    zh(
      "没有 shell 应答，用的是 app 自己的环境——里面几乎没有东西；检查 ~/.zshrc 里 nvm 的导出。",
      "No shell answered, so this is the app's own environment, which has almost nothing in it. Check the nvm export in ~/.zshrc."
    )
  }

  public var environmentLoginShellNote: String {
    zh(
      "只读到登录 shell：~/.zshrc 里的导出（nvm、代理）没有生效，dsh 可能找不到 node。",
      "Only the login shell answered: exports from ~/.zshrc (nvm, proxies) are missing, so dsh may not find node."
    )
  }

  public var environmentNodeMissing: String { zh("没有 node", "no node") }

  public func environmentTiming(_ report: EnvironmentReport) -> String {
    "\(report.durationMs) ms"
  }

  // MARK: - Quit

  public var quitField: String { zh("退出时", "On quit") }

  public var quitNote: String {
    zh(
      "「保持运行」会留下 dsh，下次打开 dsh bar 时按 pid 和端口认回来，仍然可以接管或停止。",
      "\"Keep it running\" leaves dsh alive; the next launch recognises it by pid and port, and it can still be taken over or stopped."
    )
  }

  public var handoffNote: String {
    zh(
      "上次由 dsh bar 启动，退出时保留了它。没有启动令牌，浏览器里若提示未授权，请接管或从终端打开。",
      "Started by dsh bar, kept alive when the app quit. There is no launch token: if the browser says unauthorized, take it over or open it from the terminal."
    )
  }

  public var handoffBadge: String { zh("上次由 dsh bar 启动", "started by dsh bar") }

  public var quitAskTitle: String { zh("退出 dsh bar？", "Quit dsh bar?") }

  public var quitAskBody: String {
    zh(
      "有一个由 dsh bar 启动的 dsh 正在监听。退出时停掉它，还是让它继续跑？",
      "A dsh started by dsh bar is listening. Stop it as the app quits, or leave it running?"
    )
  }

  public var quitAskStop: String { zh("退出并停止", "Quit and stop") }

  public var quitAskKeep: String { zh("退出但保留", "Quit and keep") }

  public var quitAskRemember: String { zh("记住我的选择", "Remember my choice") }

  // MARK: - Shortcut

  public var shortcutField: String { zh("唤起面板", "Show panel") }

  public var shortcutNote: String {
    zh(
      "在任何 app 里都能唤起面板；不需要辅助功能授权。",
      "Shows the panel from any app; no Accessibility permission needed."
    )
  }

  public var shortcutTaken: String {
    zh("已被其它应用占用，换一个或关闭。", "Another app already owns it. Pick another or turn it off.")
  }

  // MARK: - Launch at login

  public var launchAtLoginField: String { zh("开机自启", "Launch at login") }

  public var openLoginItems: String { zh("打开登录项…", "Open Login Items…") }

  public func loginItemState(_ status: LoginItemStatus) -> String {
    switch status {
    case .enabled: return zh("已开启", "on")
    case .requiresApproval: return zh("等待系统批准", "waiting for approval")
    case .notRegistered: return zh("未开启", "off")
    case .unavailable: return zh("不可用", "unavailable")
    }
  }

  public var loginItemUnavailableHere: String {
    zh("需要以 .app 运行才能注册登录项", "needs to run as a .app to register")
  }

  public var loginItemUnsigned: String {
    zh("ad-hoc 签名每次构建都会变，先固定签名再开", "an ad-hoc signature changes every build; sign it first")
  }

  // MARK: - Keeping the machine awake

  public var sleepField: String { zh("防止休眠", "Keep awake") }

  /// The footer word. Two characters, like the rest of the footer: it is a status,
  /// not a control, and the panel's only recessed surface is the readout band.
  public var awakeBadge: String { zh("防休眠", "awake") }

  public var sleepNote: String {
    zh(
      "只阻止系统待机休眠（caffeinate -i），屏幕仍按系统设置关闭；合盖仍然会休眠。",
      "Prevents idle system sleep only (caffeinate -i). The screen still turns off on its own schedule; closing the lid still sleeps."
    )
  }

  /// The tool's own absence, translated here rather than printed as an English
  /// sentence at a Chinese reader. A system error is passed through untouched.
  public var sleepToolMissing: String {
    zh("找不到 /usr/bin/caffeinate", "/usr/bin/caffeinate is missing")
  }

  public func sleepState(_ status: SleepGuardStatus) -> String {
    switch status {
    case .idle:
      return zh("未防止", "not asserting")
    case .asserting(let pid) where pid > 0:
      return zh("正在防止休眠 · pid \(pid)", "awake · pid \(pid)")
    case .asserting:
      // The fixture build has no process to name.
      return zh("正在防止休眠", "awake")
    case .unavailable(let reason):
      let text = reason == Caffeinate.missingReason ? sleepToolMissing : reason
      return zh("不可用：\(text)", "unavailable: \(text)")
    case .failed(let detail):
      return zh("已退出：\(detail)", "exited: \(detail)")
    }
  }

  // MARK: - Launch flags

  /// The fifth tab. Everything here is optional: an untouched install sends the
  /// same argv 0.5.0 sent.
  public var launchSection: String { zh("启动参数", "Launch flags") }


  public var hostField: String { zh("绑定地址", "Bind address") }

  public var hostPlaceholder: String { "127.0.0.1" }

  public var hostNote: String {
    zh(
      "留空只监听本机。填一个本机地址（例如 192.168.1.10）可让同网段的设备访问；通配地址和主机名 dsh 不接受。",
      "Empty listens on this machine only. A local address (192.168.1.10) lets devices on the same network in; dsh refuses wildcards and host names."
    )
  }

  public var publicURLField: String { zh("公开地址", "Public URL") }

  public var publicURLPlaceholder: String { "https://dsh.example.com/" }

  public var publicURLNote: String {
    zh(
      "反向代理或隧道后面的外部地址；只影响打印和打开的链接，不授予信任。",
      "The outside address behind a proxy or tunnel; it only changes the printed and opened link, and grants no trust."
    )
  }

  public var trustedHostsField: String { zh("信任主机", "Trusted hosts") }

  public var trustedHostsNote: String {
    zh(
      "额外允许通过 /api 浏览器信任栅栏的 authority（host 或 host:port），逗号分隔。",
      "Extra authorities the /api browser-trust fence accepts (host or host:port), comma separated."
    )
  }

  public var tlsCertField: String { zh("TLS 证书", "TLS cert") }

  public var tlsKeyField: String { zh("TLS 私钥", "TLS key") }

  public var tlsNote: String {
    zh(
      "证书与私钥必须成对；开启后只能用 https 打开，dsh bar 也不再能识别端口上的外部实例。",
      "The certificate and key must be a pair. With them on the URL is https only, and dsh bar can no longer identify an external instance on the port."
    )
  }

  public var patchField: String { zh("附加 patch", "Extra patches") }


  public var addPatch: String { zh("添加…", "Add…") }

  public var removePatch: String { zh("移除", "Remove") }

  public var clearField: String { zh("清除", "Clear") }

  public var noPatches: String { zh("没有附加 patch", "No extra patches") }

  /// One sentence per rejected flag, said next to the field that caused it and
  /// reused by the failed-launch diagnosis.
  public func launchFlagProblem(_ problem: WebLaunchFlags.Problem) -> String {
    switch problem {
    case .wildcardHost(let host):
      return zh(
        "「\(host)」是通配地址。dsh 只接受一个具体的本机地址，填 192.168.x.x 这样的地址。",
        "「\(host)」 is a wildcard. dsh takes one concrete local address, such as 192.168.x.x."
      )
    case .invalidHost(let host):
      return zh(
        "「\(host)」不是 IPv4 / IPv6 地址。",
        "「\(host)」 is not an IPv4 or IPv6 address."
      )
    case .invalidPublicURL(let url):
      return zh(
        "「\(url)」不是 http(s) 地址。",
        "「\(url)」 is not an http(s) URL."
      )
    case .invalidTrustedHost(let host):
      return zh(
        "「\(host)」不是 host 或 host:port。",
        "「\(host)」 is not a host or host:port."
      )
    case .tlsNeedsBoth:
      return zh(
        "证书和私钥必须一起填：只填一个 dsh 会直接退出。",
        "The certificate and key go together: one without the other makes dsh exit."
      )
    case .missingFile(let field, let path):
      let label: String
      switch field {
      case .tlsCert: label = zh("证书", "certificate")
      case .tlsKey: label = zh("私钥", "key")
      case .patch: label = "patch"
      default: label = zh("文件", "file")
      }
      return zh("找不到\(label)：\(path)", "The \(label) is missing: \(path)")
    case .emptyPatch:
      return zh("patch 路径是空的。", "A patch path is empty.")
    }
  }

  /// Footer words, two characters like `防休眠`: a fact about this server, not a
  /// control.
  public var lanBadge: String { zh("局域网", "LAN") }

  public var tlsBadge: String { "TLS" }

  /// One footer word instead of two: the strip is 348 points wide and already
  /// carries port, profile, the awake word and Quit.
  public func networkBadge(lan: Bool, tls: Bool) -> String? {
    switch (lan, tls) {
    case (true, true): return "\(lanBadge) · \(tlsBadge)"
    case (true, false): return lanBadge
    case (false, true): return tlsBadge
    case (false, false): return nil
    }
  }

  // MARK: - Token hygiene

  public var copyLinkRedacted: String {
    zh("复制不含凭证的链接", "Copy link without the token")
  }

  public var copyLinkHelp: String {
    zh(
      "复制的是带 token 的地址；右键菜单里可以复制不含凭证的那一份。",
      "Copies the URL with its token; the right-click menu has the version without one."
    )
  }

  public var tokenRedactedNote: String {
    zh("日志里的 token 已打码。", "Tokens are masked in the log.")
  }

  // MARK: - Folder access

  /// `~/Documents` is TCC-protected; dsh's default workspace lives inside it, so
  /// the app has to hold that grant or every launch starts with a system sheet.
  public var folderSection: String { zh("文件夹权限", "Folder access") }

  public var documentsFolder: String { zh("文稿文件夹", "Documents") }

  public var authorize: String { zh("授权…", "Authorize…") }

  public var openSystemSettings: String { zh("系统设置…", "System Settings…") }

  public var recheck: String { zh("重新检查", "Check again") }

  public var grantPrompt: String { zh("授权", "Authorize") }

  public var grantMessage: String {
    zh(
      "点「启动」时才会问这一次：选中「文稿文件夹」再点授权。dsh 的默认工作区在 ~/Documents/deepseek-harness，选过之后系统不会再问。",
      "This is asked once, when you press Start: pick the Documents folder and authorize it. dsh's default workspace lives in ~/Documents/deepseek-harness; after this the system stops asking."
    )
  }

  /// One line next to the row: what the state means for dsh, not what TCC is.
  public func folderState(_ snapshot: FolderAccessSnapshot) -> String {
    switch snapshot.state {
    case .granted:
      return zh("已授权 · \(snapshot.entryCount) 项", "granted · \(snapshot.entryCount) items")
    case .denied:
      return zh("未授权", "not authorized")
    case .notRequested:
      return zh("未请求", "not requested")
    case .missing:
      return zh("文件夹不存在", "folder missing")
    }
  }

  public var folderNote: String {
    zh(
      "只在点「启动」时问一次，之后用书签直接读。",
      "Asked once, when you press Start; the bookmark is read directly after that."
    )
  }

  public var folderDeniedNote: String {
    zh(
      "系统已记下拒绝，必须在「系统设置 → 隐私与安全性 → 文件与文件夹」里勾选 dsh bar，这里才能重新读到。",
      "The system recorded a refusal. Tick dsh bar under System Settings → Privacy & Security → Files and Folders before this can read again."
    )
  }

  public var demoMode: String {
    zh("演示模式：状态由预览场景驱动。", "Demo mode: states are driven by preview scenes.")
  }

  public func binarySource(_ source: DshDetection.Source) -> String {
    switch source {
    case .setting: return zh("设置里指定", "set in Settings")
    case .environment: return "DSHBAR_DSH_PATH"
    case .path: return "PATH"
    case .nvm: return "nvm"
    case .homebrew: return "Homebrew"
    case .localBin: return "/usr/local/bin"
    }
  }

  /// The footer line in Settings: what the app found, and what it would run.
  public func versionLabel(_ version: String?) -> String {
    guard let version, !version.isEmpty else { return notDetected }
    return "dsh \(version)"
  }

  public func portLabel(_ preferences: BarPreferences) -> String {
    preferences.isAutoPort ? portAuto : String(preferences.port)
  }

  // MARK: - Prose

  public var unavailableBody: String {
    zh(
      "dsh bar 没找到 dsh。指定它的位置，或先安装再重新检测。",
      "dsh bar couldn't find dsh. Point it at the binary, or install dsh and detect again."
    )
  }

  public var externalNote: String {
    zh(
      "dsh bar 没有它的启动令牌。若浏览器提示未授权，请从启动它的终端打开。",
      "dsh bar has no launch token for it. If the browser says unauthorized, open it from the terminal that started it."
    )
  }

  /// Title and body for the failure diagnosis block.
  public func diagnosis(_ failure: HarnessFailure) -> (title: String, body: String) {
    switch failure.kind {
    case let .portInUse(port):
      return (
        zh("端口 \(port) 已被占用。", "Port \(port) is in use."),
        zh(
          "另一个进程正在监听这个端口。可以让系统挑一个空闲端口，或先停掉那个进程。",
          "Another process is listening there. Let dsh bar pick a free port, or stop that process first."
        )
      )
    case .nodeMissing:
      return (
        zh("找不到 node。", "node is missing."),
        zh(
          "dsh 是 #!/usr/bin/env node 脚本，但 dsh bar 拿到的 PATH 里没有 node。图形界面启动的 app 不会读 ~/.zshrc，而 nvm 一般只写在那里——dsh bar 现在会读交互式登录 shell，并把 dsh 所在目录放到 PATH 最前面。仍然失败时，检查 ~/.zshrc 里 nvm 的导出，或把 node 装到 /opt/homebrew/bin。",
          "dsh is a #!/usr/bin/env node script, but no node is on the PATH dsh bar builds. A GUI-launched app never reads ~/.zshrc, which is where nvm normally lives; dsh bar now reads the interactive login shell and puts dsh's own directory first on PATH. If it still fails, check the nvm export in ~/.zshrc, or install node somewhere on PATH."
        )
      )
    case .workspaceMissing(let path):
      return (
        zh("工作目录不可用。", "The working directory is unusable."),
        zh(
          "dsh bar 不能在这个目录里启动 dsh：\(path)。它不存在，或者不是文件夹——GUI app 的当前目录是 /，所以相对路径也没有意义。点「改回默认」，让 dsh 用自己的工作区。",
          "dsh bar can't start dsh in \(path): it is missing, or not a folder. A GUI app's working directory is /, so a relative path means nothing here. Press Use defaults and let dsh pick its own workspace."
        )
      )
    case .dshHomeMissing(let path):
      return (
        zh("DSH_HOME 不可用。", "DSH_HOME is unusable."),
        zh(
          "设置里指定的 DSH_HOME 指向 \(path)，但它不是文件夹，dsh bar 也不会替你覆盖它。点「改回默认」，跟随登录 shell 的 DSH_HOME。",
          "The DSH_HOME in Settings points at \(path), which is not a folder — and dsh bar will not overwrite it. Press Use defaults to follow the login shell's DSH_HOME again."
        )
      )
    case .launchFlags(let problem):
      return (
        zh("启动参数不可用。", "A launch flag is unusable."),
        zh(
          "\(launchFlagProblem(problem))在设置 › 启动里改好，再按启动。",
          "\(launchFlagProblem(problem)) Fix it under Settings › Launch, then press Start again."
        )
      )
    case .binaryMissing:
      return (
        zh("找不到或无法执行 dsh。", "dsh is missing or not executable."),
        zh(
          "在设置里指定 dsh 的路径，或先安装 dsh。",
          "Point dsh bar at the dsh binary in Settings, or install dsh first."
        )
      )
    case let .exited(code):
      let codeText = code.map { String($0) } ?? "?"
      return (
        zh("dsh 在启动时退出了（退出码 \(codeText)）。", "dsh exited during startup (code \(codeText))."),
        zh("查看下面的输出，或打开完整日志。", "Check the output below, or open the full log.")
      )
    case let .timeout(seconds):
      return (
        zh("dsh 没有在 \(seconds) 秒内报出地址。", "dsh didn't report an address within \(seconds) seconds."),
        zh("它可能仍在启动，查看日志确认。", "It may still be starting. Check the log.")
      )
    }
  }

  // MARK: - Formatting

  /// Compact duration: seconds under a minute, minutes and seconds under an
  /// hour, hours and minutes beyond that.
  public func duration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if language == .zhHans {
      if h > 0 { return "已运行 \(h) 小时 \(m) 分" }
      if m > 0 { return "已运行 \(m) 分 \(s) 秒" }
      return "已运行 \(s) 秒"
    }
    if h > 0 { return "up \(h)h \(m)m" }
    if m > 0 { return "up \(m)m \(s)s" }
    return "up \(s)s"
  }
}
