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
  /// When the last unexpected exit happened. Set once the crash decision is made.
  public var lastCrashAt: Date?
  /// When the watchdog has already decided to act on a crash, so the second
  /// `.exited` of the same crash (a queued signal) cannot restart twice.
  public var crashHandled: Bool
  /// Port and profile for the next automatic spawn. Nil when there is nothing to
  /// restart (the server was started by hand from a terminal).
  public var retryTarget: RetryTarget?
  /// Attempts inside `CrashWatchdog.window`, newest last.
  public var attempts: [Date]
  /// True when the start in flight is the watchdog's, so the attempts survive it.
  public var retrying: Bool
  /// How many attempts the last give-up used, for the notification.
  public var gaveUpAfter: Int?

  public init(snapshot: HarnessSnapshot = HarnessSnapshot()) {
    self.snapshot = snapshot
    self.launchURL = nil
    self.startedAt = nil
    self.intentionalStop = false
    self.announced = false
    self.pendingDetail = nil
    self.searched = []
    self.lastCrashAt = nil
    self.crashHandled = false
    self.retryTarget = nil
    self.attempts = []
    self.retrying = false
    self.gaveUpAfter = nil
  }
}

/// What the watchdog would spawn next. A struct, not a tuple: `HarnessState` is
/// `Equatable` and the reducer's "nothing changed" answers depend on it.
public struct RetryTarget: Sendable, Equatable {
  public var port: Int
  public var profile: String

  public init(port: Int, profile: String) {
    self.port = port
    self.profile = profile
  }
}

/// Inputs the controller turns into state changes. Everything the process layer
/// observes arrives here, which is what makes the transitions assertable.
public enum HarnessEvent: Sendable, Equatable {
  case detected(path: String)
  case detectionFailed(searched: [String])
  case start(port: Int, profile: String)
  /// Settings changed while nothing is running: follow the new port/profile.
  case preferencesChanged(port: Int, profile: String)
  /// A dsh someone else started is on the port we are supposed to use.
  case observedExternal(port: Int)
  /// A server this app started in an earlier run and kept alive on purpose.
  case observedHandoff(port: Int)
  /// That server is gone again.
  case observedFree(port: Int)
  case portChecked(PortState, port: Int)
  case spawnFailed(HarnessFailure)
  case launch(LaunchLine)
  case exited(code: Int32?, signal: Int32?)
  /// A stop that did not take: the external server is still holding the port.
  case stopFailed(port: Int, detail: String)
  case stopRequested
  case killTimedOut
  case cancel
  case readyTimeout(seconds: Int)
  case tick
  case reset
  /// The watchdog's timer: spawn again, or stop for good when it is out of budget.
  case restartDue
  /// The watchdog is switched off, or the user pressed Cancel during a restart.
  case restartAbandoned
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
  /// Wait, then send `.restartDue`.
  case scheduleRestart(delay: Int)
  case cancelRestart
  /// Spawn at once for the watchdog: port 0 skips the probe, anything else probes
  /// first, exactly like a hand start.
  case restartNow(port: Int)
}

public enum HarnessReducer {
  /// How long dsh gets to print its URL. Measured cold start is about 2 seconds;
  /// 30 leaves room for a slow disk, a first `pnpm` resolution, or a debugger.
  public static let readyTimeout = 30
  /// SIGTERM gets five seconds before SIGKILL: dsh closes its store cleanly.
  public static let stopGrace = 5

  /// - Parameter autoRestart: the preference, read by the caller so the reducer
  ///   stays a pure function of what it is told.
  public static func reduce(
    _ state: HarnessState,
    _ event: HarnessEvent,
    language: UILanguage,
    now: Date = Date(),
    autoRestart: Bool = true
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
      // Starting by hand while the watchdog is waiting is allowed and beats the
      // timer: the user's decision replaces a scheduled retry, and the budget
      // starts over.
      guard [.stopped, .failed, .unavailable, .restarting].contains(next.snapshot.phase) else {
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
      next.snapshot.handoff = false
      next.launchURL = nil
      next.startedAt = nil
      next.intentionalStop = false
      next.announced = false
      next.pendingDetail = nil
      // A hand-started server is the user's decision, and it starts a fresh crash
      // budget: "it was fine after I looked at it" should not be punished.
      next.crashHandled = false
      next.attempts = []
      next.snapshot.restartAttempt = nil
      next.snapshot.restartDelay = nil
      next.retrying = false
      next.retryTarget = RetryTarget(port: port, profile: profile)
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
        next.snapshot.handoff = false
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

    case .preferencesChanged(let port, let profile):
      guard [.stopped, .failed, .unavailable].contains(next.snapshot.phase) else {
        return (state, [])
      }
      next.snapshot.port = port
      next.snapshot.profile = profile

    case .observedExternal(let port):
      guard let adopted = adoptExternal(next, port: port, handoff: false) else { return (state, []) }
      return (adopted, [.stopUptime])

    case .observedHandoff(let port):
      guard let adopted = adoptExternal(next, port: port, handoff: true) else { return (state, []) }
      return (adopted, [.stopUptime])

    case .observedFree(let port):
      // An external server that disappears is not a failure: the user closed it
      // in their terminal, which is exactly what "managed nowhere" looks like.
      guard next.snapshot.phase == .listening,
            next.snapshot.owner == .external,
            port == next.snapshot.port
      else { return (state, []) }
      next.snapshot.phase = .stopped
      next.snapshot.busy = false
      next.snapshot.uptime = nil
      next.snapshot.hasLaunchURL = false
      next.snapshot.handoff = false
      next.snapshot.failure = nil
      next.snapshot.lastRun = justNow(language)
      next.launchURL = nil
      commands = [.stopUptime]

    case .spawnFailed(let failure):
      next.snapshot.phase = .failed
      next.snapshot.busy = false
      next.snapshot.handoff = false
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
        next.pendingDetail = nil
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
        next.retrying = false
        next.crashHandled = false
        next.snapshot.restartAttempt = nil
        next.snapshot.restartDelay = nil
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
        // Only a start in flight owns this detail; a late line from an earlier
        // run must not colour the next failure.
        guard next.snapshot.phase == .starting else { return (state, []) }
        next.pendingDetail = detail
        commands = []

      case .ignored:
        commands = []
      }

    case .exited(let code, let signal):
      next.snapshot.uptime = nil
      next.snapshot.hasLaunchURL = false
      next.snapshot.handoff = false
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
        let failure = HarnessFailure(
          kind: .exited(code: signal == nil ? code : nil),
          detail: next.pendingDetail ?? (signal.map { "signal \($0)" })
        )
        next.snapshot.lastRun = justNow(language)
        next.snapshot.hasLaunchURL = false
        commands = [.stopUptime, .disarmReadyTimeout]
        if autoRestart, !next.crashHandled, let target = next.retryTarget {
          next.crashHandled = true
          next.lastCrashAt = now
          switch CrashWatchdog.decide(attempts: next.attempts, now: now) {
          case .restart(let attempt, let delay):
            next.attempts.append(now)
            next.snapshot.phase = .restarting
            next.snapshot.failure = failure
            next.snapshot.busy = true
            next.snapshot.restartAttempt = attempt
            next.snapshot.restartDelay = delay
            next.snapshot.port = target.port
            next.snapshot.profile = target.profile
            next.launchURL = nil
            next.startedAt = nil
            next.announced = false
            next.intentionalStop = false
            commands.append(.scheduleRestart(delay: delay))
          case .giveUp(let attempts):
            next.snapshot.phase = .failed
            next.snapshot.failure = failure
            next.snapshot.busy = false
            next.snapshot.restartAttempt = nil
            next.snapshot.restartDelay = nil
            next.gaveUpAfter = attempts
          }
        } else {
          next.snapshot.phase = .failed
          next.snapshot.failure = failure
        }
      case .starting:
        next.snapshot.phase = .failed
        next.snapshot.failure = HarnessFailure(
          kind: .exited(code: signal == nil ? code : nil),
          detail: next.pendingDetail
        )
        next.pendingDetail = nil
        commands = [.disarmReadyTimeout, .stopUptime]
      case .stopped, .failed, .unavailable, .restarting:
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

    case .stopFailed(let port, let detail):
      guard next.snapshot.phase == .stopping else { return (state, []) }
      next.snapshot.phase = .failed
      next.snapshot.busy = false
      next.snapshot.hasLaunchURL = false
      next.snapshot.uptime = nil
      next.snapshot.failure = HarnessFailure(kind: .portInUse(port: port), detail: detail)
      next.snapshot.handoff = false
      next.launchURL = nil
      next.intentionalStop = false
      commands = [.stopUptime, .disarmReadyTimeout]

    case .killTimedOut:
      guard next.snapshot.phase == .stopping else { return (state, []) }
      commands = [.kill]

    case .cancel:
      guard next.snapshot.phase == .starting || next.snapshot.phase == .restarting else {
        return (state, [])
      }
      let wasRestarting = next.snapshot.phase == .restarting
      next.snapshot.restartAttempt = nil
      next.snapshot.restartDelay = nil
      next.retrying = false
      next.snapshot.phase = .stopped
      next.snapshot.busy = false
      next.snapshot.uptime = nil
      next.snapshot.lastRun = nil
      next.snapshot.hasLaunchURL = false
      next.launchURL = nil
      next.startedAt = nil
      next.announced = false
      next.intentionalStop = true
      commands = wasRestarting ? [.cancelRestart, .disarmReadyTimeout] : [.disarmReadyTimeout, .terminate]

    case .readyTimeout(let seconds):
      guard next.snapshot.phase == .starting else { return (state, []) }
      next.snapshot.phase = .failed
      next.snapshot.busy = false
      next.snapshot.failure = HarnessFailure(kind: .timeout(seconds: seconds))
      next.snapshot.hasLaunchURL = false
      commands = [.disarmReadyTimeout, .terminate]

    case .restartDue:
      guard next.snapshot.phase == .restarting, let target = next.retryTarget else {
        return (state, [])
      }
      // Same shape as a start, minus the budget reset: the panel keeps saying
      // "Starting…" with the attempt in the readout, and the port is probed again
      // in case whatever held it has let go.
      next.retrying = true
      next.snapshot.phase = .starting
      next.snapshot.busy = true
      next.snapshot.hasLaunchURL = false
      next.snapshot.uptime = nil
      next.snapshot.log = []
      next.snapshot.port = target.port
      next.snapshot.profile = target.profile
      next.snapshot.restartDelay = nil
      next.launchURL = nil
      next.startedAt = nil
      next.intentionalStop = false
      next.announced = false
      next.pendingDetail = nil
      commands = [.writeLogSeparator, .restartNow(port: target.port)]

    case .restartAbandoned:
      guard next.snapshot.phase == .restarting else { return (state, []) }
      next.snapshot.phase = .failed
      next.snapshot.busy = false
      next.snapshot.restartAttempt = nil
      next.snapshot.restartDelay = nil
      next.crashHandled = true
      commands = [.cancelRestart]

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
      next.snapshot.handoff = false
      commands = [.stopUptime, .disarmReadyTimeout]
    }

    return (next, commands)
  }

  /// Both "someone else is on the port" cases land in the same state; only the note
  /// on the panel differs. One body keeps them from drifting apart.
  private static func adoptExternal(_ state: HarnessState, port: Int, handoff: Bool) -> HarnessState? {
    guard state.snapshot.phase == .stopped else { return nil }
    var next = state
    next.snapshot.phase = .listening
    next.snapshot.owner = .external
    next.snapshot.handoff = handoff
    next.snapshot.hasLaunchURL = false
    next.snapshot.uptime = nil
    next.snapshot.busy = false
    next.snapshot.failure = nil
    next.snapshot.port = port
    next.snapshot.log = []
    next.launchURL = nil
    next.startedAt = nil
    next.announced = false
    return next
  }

  private static func justNow(_ language: UILanguage) -> String {
    language == .zhHans ? "刚刚" : "just now"
  }
}
