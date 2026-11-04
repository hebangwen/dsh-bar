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
    case exited(code: Int32?)
    case timeout(seconds: Int)
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
    busy: Bool = false
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
  }

  public var address: String { "\(host):\(port)" }

  /// The panel shows the output well whenever there is something to read.
  public var showsLog: Bool {
    switch phase {
    case .listening, .failed: return !log.isEmpty || phase == .failed
    case .starting, .stopping, .unavailable: return false
    case .stopped: return false
    }
  }

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
