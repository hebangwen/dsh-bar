import Foundation

/// Everything the controller must remember beyond what the panel draws.
///
/// The snapshot stays the only thing the view reads; this adds the few facts the
/// state machine needs and the panel does not: the launch URL, when the process
/// started, and whether the current exit was asked for.
public struct HarnessState: Sendable, Equatable {
  public var snapshot: HarnessSnapshot
  /// The authenticated URL dsh printed. Nil while there is none to hand out.
  public var launchURL: String?
  /// When the server started listening, for uptime.
  public var startedAt: Date?
  /// True between the user pressing Stop and the process exiting, so the exit is
  /// reported as `stopped` rather than as a crash.
  public var intentionalStop: Bool
  /// dsh prints its URL once; a repeat is not a second server.
  public var announced: Bool
  /// The `dsh: startup failed` line, kept until the exit code arrives.
  public var pendingDetail: String?
  /// What the locator tried, for the "not found" panel.
  public var searched: [String]

  public init(snapshot: HarnessSnapshot = HarnessSnapshot()) {
    self.snapshot = snapshot
    self.launchURL = nil
    self.startedAt = nil
    self.intentionalStop = false
    self.announced = false
    self.pendingDetail = nil
    self.searched = []
  }
}

/// Inputs the controller turns into state changes. Everything the process layer
/// observes arrives here, which is what makes the transitions assertable.
public enum HarnessEvent: Sendable, Equatable {
  case detected(path: String)
  case detectionFailed(searched: [String])
  case start(port: Int, profile: String)
  case portChecked(PortState, port: Int)
  case spawnFailed(HarnessFailure)
  case launch(LaunchLine)
  case exited(code: Int32?, signal: Int32?)
  case stopRequested
  case killTimedOut
  case cancel
  case readyTimeout(seconds: Int)
  case tick
  case reset
}

/// What the controller should do about it. The reducer never touches a process;
/// it names the side effect and the backend performs it.
public enum HarnessCommand: Sendable, Equatable {
  case probePort(Int)
  case spawn(port: Int)
  case armReadyTimeout(seconds: Int)
  case disarmReadyTimeout
  case startUptime
  case stopUptime
  case terminate
  case kill
  case stopExternal(port: Int)
  case writeLogSeparator
}

public enum HarnessReducer {
  /// How long dsh gets to print its URL. Measured cold start is about 2 seconds;
  /// 30 leaves room for a slow disk, a first `pnpm` resolution, or a debugger.
  public static let readyTimeout = 30
  /// SIGTERM gets five seconds before SIGKILL: dsh closes its store cleanly.
  public static let stopGrace = 5

  public static func reduce(
    _ state: HarnessState,
    _ event: HarnessEvent,
    language: UILanguage,
    now: Date = Date()
  ) -> (HarnessState, [HarnessCommand]) {
    var next = state
    var commands: [HarnessCommand] = []

    switch event {
    case .detected:
      next.searched = []
      if next.snapshot.phase == .unavailable {
        next.snapshot.phase = .stopped
        next.snapshot.failure = nil
      }

    case .detectionFailed(let searched):
      next.searched = searched
      next.snapshot.phase = .unavailable
      next.snapshot.busy = false
      next.snapshot.uptime = nil
      next.snapshot.hasLaunchURL = false
      next.snapshot.log = []
      next.snapshot.failure = HarnessFailure(
        kind: .binaryMissing,
        detail: searched.first
      )
      next.launchURL = nil
      commands = [.stopUptime, .disarmReadyTimeout]

    case .start(let port, let profile):
      guard [.stopped, .failed, .unavailable].contains(next.snapshot.phase) else {
        return (state, [])
      }
      next.snapshot.phase = .starting
      next.snapshot.busy = true
      next.snapshot.owner = .dshBar
      next.snapshot.hasLaunchURL = false
      next.snapshot.uptime = nil
      next.snapshot.failure = nil
      next.snapshot.log = []
      next.snapshot.port = port
      next.snapshot.profile = profile
      next.snapshot.lastRun = nil
      next.launchURL = nil
      next.startedAt = nil
      next.intentionalStop = false
      next.announced = false
      next.pendingDetail = nil
      commands = [.writeLogSeparator]
      // Port 0 asks the OS to pick one, so there is nothing to check first.
      if port == BarPreferences.autoPort {
        commands.append(.spawn(port: port))
        commands.append(.armReadyTimeout(seconds: readyTimeout))
      } else {
        commands.append(.probePort(port))
      }

    case .portChecked(let portState, let port):
      guard next.snapshot.phase == .starting else { return (state, []) }
      switch portState {
      case .free:
        commands = [.spawn(port: port), .armReadyTimeout(seconds: readyTimeout)]
      case .dsh:
        next.snapshot.phase = .listening
        next.snapshot.owner = .external
        next.snapshot.hasLaunchURL = false
        next.snapshot.uptime = nil
        next.snapshot.busy = false
        next.snapshot.failure = nil
        next.launchURL = nil
        next.startedAt = nil
        commands = [.disarmReadyTimeout]
      case .other:
        next.snapshot.phase = .failed
        next.snapshot.busy = false
        next.snapshot.failure = HarnessFailure(kind: .portInUse(port: port))
        next.snapshot.hasLaunchURL = false
        commands = [.disarmReadyTimeout]
      }

    case .spawnFailed(let failure):
      next.snapshot.phase = .failed
      next.snapshot.busy = false
      next.snapshot.failure = failure
      next.snapshot.hasLaunchURL = false
      next.snapshot.uptime = nil
      next.announced = false
      commands = [.disarmReadyTimeout, .stopUptime]

    case .launch(let line):
      switch line {
      case .ready(let report):
        guard next.snapshot.phase == .starting, !next.announced else { return (state, []) }
        next.announced = true
        next.snapshot.phase = .listening
        next.snapshot.owner = .dshBar
        next.snapshot.host = report.host
        next.snapshot.port = report.port
        next.snapshot.hasLaunchURL = true
        next.snapshot.uptime = 0
        next.snapshot.busy = false
        next.snapshot.failure = nil
        next.launchURL = report.url
        next.startedAt = now
        commands = [.disarmReadyTimeout, .startUptime]

      case .portInUse(let port):
        guard next.snapshot.phase == .starting else { return (state, []) }
        next.snapshot.phase = .failed
        next.snapshot.busy = false
        next.snapshot.failure = HarnessFailure(kind: .portInUse(port: port ?? next.snapshot.port))
        next.snapshot.hasLaunchURL = false
        next.launchURL = nil
        commands = [.disarmReadyTimeout, .terminate]

      case .startupFailed(let detail):
        next.pendingDetail = detail
        commands = []

      case .ignored:
        commands = []
      }

    case .exited(let code, let signal):
      next.snapshot.uptime = nil
      next.snapshot.hasLaunchURL = false
      next.launchURL = nil
      next.startedAt = nil
      next.announced = false
      next.snapshot.busy = false
      switch next.snapshot.phase {
      case .stopping:
        next.snapshot.phase = .stopped
        next.snapshot.lastRun = justNow(language)
        next.snapshot.failure = nil
        next.intentionalStop = false
        commands = [.stopUptime, .disarmReadyTimeout]
      case .listening:
        next.snapshot.phase = .failed
        next.snapshot.failure = HarnessFailure(
          kind: .exited(code: signal == nil ? code : nil),
          detail: next.pendingDetail ?? (signal.map { "signal \($0)" })
        )
        next.snapshot.lastRun = justNow(language)
        commands = [.stopUptime, .disarmReadyTimeout]
      case .starting:
        next.snapshot.phase = .failed
        next.snapshot.failure = HarnessFailure(
          kind: .exited(code: signal == nil ? code : nil),
          detail: next.pendingDetail
        )
        next.pendingDetail = nil
        commands = [.disarmReadyTimeout, .stopUptime]
      case .stopped, .failed, .unavailable:
        commands = [.stopUptime, .disarmReadyTimeout]
      }

    case .stopRequested:
      guard next.snapshot.phase == .listening else { return (state, []) }
      next.snapshot.phase = .stopping
      next.snapshot.busy = true
      next.snapshot.hasLaunchURL = false
      next.launchURL = nil
      next.intentionalStop = true
      commands = [.stopUptime, .disarmReadyTimeout]
      if next.snapshot.owner == .external {
        commands.append(.stopExternal(port: next.snapshot.port))
      } else {
        commands.append(.terminate)
      }

    case .killTimedOut:
      guard next.snapshot.phase == .stopping else { return (state, []) }
      commands = [.kill]

    case .cancel:
      guard next.snapshot.phase == .starting else { return (state, []) }
      next.snapshot.phase = .stopped
      next.snapshot.busy = false
      next.snapshot.uptime = nil
      next.snapshot.lastRun = nil
      next.snapshot.hasLaunchURL = false
      next.launchURL = nil
      next.startedAt = nil
      next.announced = false
      next.intentionalStop = true
      commands = [.disarmReadyTimeout, .terminate]

    case .readyTimeout(let seconds):
      guard next.snapshot.phase == .starting else { return (state, []) }
      next.snapshot.phase = .failed
      next.snapshot.busy = false
      next.snapshot.failure = HarnessFailure(kind: .timeout(seconds: seconds))
      next.snapshot.hasLaunchURL = false
      commands = [.disarmReadyTimeout, .terminate]

    case .tick:
      guard let started = next.startedAt, next.snapshot.phase == .listening else {
        return (state, [])
      }
      next.snapshot.uptime = max(0, now.timeIntervalSince(started))
      commands = []

    case .reset:
      next = HarnessState(snapshot: next.snapshot)
      next.snapshot.phase = .stopped
      next.snapshot.busy = false
      next.snapshot.uptime = nil
      next.snapshot.hasLaunchURL = false
      next.snapshot.failure = nil
      next.snapshot.log = []
      next.snapshot.lastRun = nil
      commands = [.stopUptime, .disarmReadyTimeout]
    }

    return (next, commands)
  }

  private static func justNow(_ language: UILanguage) -> String {
    language == .zhHans ? "刚刚" : "just now"
  }
}
