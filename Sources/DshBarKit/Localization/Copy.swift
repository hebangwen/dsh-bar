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
        return zh("由终端启动", "started in a terminal")
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
      if snapshot.failure?.port != nil { return zh("换一个空闲端口", "Use a free port") }
      return zh("查看日志", "Show log")
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
