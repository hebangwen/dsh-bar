import Foundation

/// The lifecycle of the managed `dsh --profile web` process, as the panel renders it.
///
/// The model is deliberately a plain value type: the panel never talks to a process.
/// Anything that can change the panel is expressed here, which keeps snapshots,
/// tests, and the demo driver identical to the real controller.
public enum HarnessPhase: String, Sendable, Equatable, CaseIterable {
  /// No usable `dsh` binary was found.
  case unavailable
  /// Known to be down (never started, or stopped cleanly).
  case stopped
  /// A child process was spawned and has not reported its URL yet.
  case starting
  /// Something answers on the port. Owned by us, or started elsewhere.
  case listening
  /// SIGTERM was sent and the process has not exited yet.
  case stopping
  /// The server died while serving and the watchdog is waiting to try again.
  /// Nothing is running during this phase; `restartAttempt` and `restartDelay`
  /// say which try it is and how long the wait is.
  case restarting
  /// The last attempt ended badly; `failure` explains how.
  case failed
}

/// Who started the server that is listening on the port.
public enum ServerOwner: Sendable, Equatable {
  /// This app spawned it, so it holds the launch token and may stop it freely.
  case dshBar
  /// Something started it outside the app (a terminal, a launch agent).
  /// The launch token is unknown, so opening it is only best-effort.
  case external
}

/// Why the last start attempt failed. The kind drives the diagnosis copy;
/// `detail` carries the raw line dsh printed, when there is one.
public struct HarnessFailure: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case portInUse(port: Int)
    case binaryMissing
    /// dsh is a `#!/usr/bin/env node` script and no `node` is on the PATH it would
    /// get. Its own error line (`env: node: No such file or directory`) reads like
    /// a dsh problem, so it gets its own kind and its own explanation.
    case nodeMissing
    /// The configured working directory is not there. `posix_spawn` would fail with
    /// an unrelated error, so the app refuses the spawn and says which path it is.
    case workspaceMissing(path: String)
    /// `DSH_HOME` is configured but points at something that is not a directory.
    case dshHomeMissing(path: String)
    /// One of the optional `dsh web` flags in Settings cannot be sent: a wildcard
    /// bind address, a certificate that moved, a patch file that is gone. The app
    /// refuses the spawn instead of letting dsh fail with its own wording.
    case launchFlags(WebLaunchFlags.Problem)
    case exited(code: Int32?)
    case timeout(seconds: Int)
  }

  /// The one-click repair offered next to a failure. Failures without a recovery
  /// keep the single "Try again" button, so the panel never invents an action that
  /// cannot work.
  public enum Recovery: Sendable, Equatable {
    /// Let the OS pick a port instead.
    case freePort
    /// Forget the configured workspace / `DSH_HOME` and go back to dsh's defaults.
    case defaultPaths
  }

  public var kind: Kind
  public var detail: String?

  public init(kind: Kind, detail: String? = nil) {
    self.kind = kind
    self.detail = detail
  }

  public var port: Int? {
    if case let .portInUse(port) = kind { return port }
    return nil
  }

  public var recovery: Recovery? {
    switch kind {
    case .portInUse: return .freePort
    case .workspaceMissing, .dshHomeMissing: return .defaultPaths
    case .binaryMissing, .nodeMissing, .exited, .timeout, .launchFlags: return nil
    }
  }

  /// The path the failure is about, when it is about one.
  public var path: String? {
    switch kind {
    case .workspaceMissing(let path), .dshHomeMissing(let path): return path
    case .launchFlags(let problem):
      if case let .missingFile(_, path) = problem { return path }
      return nil
    default: return nil
    }
  }
}

/// One captured output line. `time` is pre-formatted so the view stays pure.
public struct LogLine: Sendable, Equatable, Identifiable {
  public var id: Int
  public var time: String
  public var text: String
  /// The launch-token line and errors are worth reading first.
  public var emphasized: Bool
  /// Which pipe it came from; dsh prints the launch URL to stdout and plugin
  /// noise to stderr.
  public var stream: LogStream

  public init(
    id: Int,
    time: String,
    text: String,
    emphasized: Bool = false,
    stream: LogStream = .out
  ) {
    self.id = id
    self.time = time
    self.text = text
    self.emphasized = emphasized
    self.stream = stream
  }
}

/// Everything the panel draws, and nothing else.
public struct HarnessSnapshot: Sendable, Equatable {
  public var phase: HarnessPhase
  public var host: String
  public var port: Int
  public var profile: String
  public var owner: ServerOwner
  /// False when the process is up but never printed a launch URL: the app can
  /// describe the server but cannot authenticate to it.
  public var hasLaunchURL: Bool
  /// Seconds since the process began listening. Nil while not listening.
  public var uptime: TimeInterval?
  /// How long ago the last run ended, pre-formatted ("2 小时前" / "2h ago").
  public var lastRun: String?
  public var failure: HarnessFailure?
  public var log: [LogLine]
  /// True while a transition is in flight, so actions disable themselves.
  public var busy: Bool
  /// The external server on the port is one this app started in an earlier run and
  /// left alive on purpose. It changes the explanation, never the actions: it is
  /// still an external process with no token.
  public var handoff: Bool
  /// True only while a caffeinate process is actually holding the idle-sleep
  /// assertion for this server. The preference is not this flag: the panel draws
  /// the fact, and the fact can be absent (tool missing, guard died).
  public var awake: Bool
  /// The `--host` the server is bound to (or would be, before a start). Nil means
  /// dsh's own default, which is loopback.
  public var bindHost: String?
  /// `--tls-cert` and `--tls-key` were both sent: the printed URL is https.
  public var secure: Bool
  /// Which automatic restart this is (1-based), while `.restarting`.
  public var restartAttempt: Int?
  /// Seconds the watchdog is waiting before the next spawn.
  public var restartDelay: Int?

  public init(
    phase: HarnessPhase = .stopped,
    host: String = "127.0.0.1",
    port: Int = 3080,
    profile: String = "web",
    owner: ServerOwner = .dshBar,
    hasLaunchURL: Bool = true,
    uptime: TimeInterval? = nil,
    lastRun: String? = nil,
    failure: HarnessFailure? = nil,
    log: [LogLine] = [],
    busy: Bool = false,
    handoff: Bool = false,
    awake: Bool = false,
    bindHost: String? = nil,
    secure: Bool = false,
    restartAttempt: Int? = nil,
    restartDelay: Int? = nil
  ) {
    self.phase = phase
    self.host = host
    self.port = port
    self.profile = profile
    self.owner = owner
    self.hasLaunchURL = hasLaunchURL
    self.uptime = uptime
    self.lastRun = lastRun
    self.failure = failure
    self.log = log
    self.busy = busy
    self.handoff = handoff
    self.awake = awake
    self.bindHost = bindHost
    self.secure = secure
    self.restartAttempt = restartAttempt
    self.restartDelay = restartDelay
  }

  /// What the readout band shows. While serving, the printed URL is the truth (a
  /// `--public-url` proxy entry can differ from the bind address); before a start,
  /// the configured bind address is, because that is what Start will do.
  public var address: String {
    let shown = phase == .listening ? host : (bindHost ?? host)
    return "\(shown):\(port)"
  }

  /// Serving beyond the machine: worth a word in the footer, because it is a
  /// security decision the user made once in Settings.
  public var sharesOnLAN: Bool {
    guard let bindHost else { return false }
    return !WebLaunchFlags.isLoopback(bindHost)
  }

  /// The panel shows the output well whenever there is something to read.
  public var showsLog: Bool {
    switch phase {
    case .listening, .failed: return !log.isEmpty || phase == .failed
    case .starting, .stopping, .restarting, .unavailable: return false
    case .stopped: return false
    }
  }

  /// True while the watchdog owns the transition: the panel offers Cancel instead
  /// of Start, because the next spawn is already decided.
  public var isRestarting: Bool { phase == .restarting }

  /// Manual stop is only offered when there is something to stop, and an
  /// externally owned server requires an explicit second click.
  public var offersStop: Bool {
    phase == .listening
  }

  public var needsStopConfirmation: Bool {
    phase == .listening && owner == .external
  }

  public var canOpen: Bool {
    phase == .listening
  }
}
