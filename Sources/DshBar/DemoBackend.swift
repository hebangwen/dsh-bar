import AppKit
import Foundation
import DshBarKit

/// The appearance-review driver: the same states, on a timer instead of a process.
///
/// It exists so the panel can be clicked through, screenshotted, and judged
/// without a dsh install, and so the menus keep a way to reach every state.
@MainActor
final class DemoBackend: HarnessBackend {
  var onSnapshot: ((HarnessSnapshot) -> Void)?
  private(set) var launchURL: String?

  private let language: UILanguage
  private var port: Int
  private var profile: String
  private var snapshot: HarnessSnapshot
  private var startedAt: Date?
  private var ticker: Timer?
  /// The fixture build has no caffeinate of its own; it mirrors the rule so the
  /// footer marker and the settings row can be reviewed without a real server.
  private var sleepPolicy: SleepPolicy = .default
  private var pending: DispatchWorkItem?

  init(language: UILanguage, port: Int, profile: String) {
    self.language = language
    self.port = port
    self.profile = profile
    var initial = Fixtures.snapshot(for: .stopped, copy: Copy(language: language), port: port)
    initial.profile = profile
    initial.lastRun = nil
    snapshot = initial
  }

  // MARK: - HarnessBackend

  func start(port: Int, profile: String) {
    guard snapshot.phase == .stopped || snapshot.phase == .failed else { return }
    self.port = BarPreferences.normalizePort(port)
    self.profile = BarPreferences.normalizeProfile(profile)
    pending?.cancel()

    var next = snapshot
    next.phase = .starting
    next.port = self.port
    next.profile = self.profile
    next.owner = .dshBar
    next.busy = true
    next.uptime = nil
    next.failure = nil
    next.lastRun = nil
    next.hasLaunchURL = false
    next.log = Array(Fixtures.log(port: self.port).prefix(2))
    publish(next)

    after(1.4) { [weak self] in
      guard let self else { return }
      self.startedAt = Date()
      var ready = self.snapshot
      ready.phase = .listening
      ready.owner = .dshBar
      ready.busy = false
      ready.hasLaunchURL = true
      ready.uptime = 0
      ready.failure = nil
      ready.log = Fixtures.log(port: self.port)
      self.publish(ready)
      self.startTicking()
    }
  }

  func stop() {
    pending?.cancel()
    stopTicking()
    var next = snapshot
    next.phase = .stopping
    next.busy = true
    next.hasLaunchURL = false
    next.log = []
    publish(next)

    after(0.9) { [weak self] in
      guard let self else { return }
      self.startedAt = nil
      var stopped = Fixtures.snapshot(for: .stopped, copy: Copy(language: self.language), port: self.port)
      stopped.profile = self.profile
      stopped.lastRun = self.language == .zhHans ? "刚刚" : "just now"
      self.publish(stopped)
    }
  }

  func cancel() {
    guard snapshot.phase == .starting else { return }
    pending?.cancel()
    stopTicking()
    startedAt = nil
    var next = Fixtures.snapshot(for: .stopped, copy: Copy(language: language), port: port)
    next.profile = profile
    next.lastRun = nil
    publish(next)
  }

  func update(_ preferences: BarPreferences) {
    port = preferences.port
    profile = preferences.profile
    if sleepPolicy != preferences.sleepPolicy {
      sleepPolicy = preferences.sleepPolicy
      var next = snapshot
      next.awake = shouldAssert
      publish(next)
    }
  }

  var sleepStatus: SleepGuardStatus { shouldAssert ? .asserting(pid: 0) : .idle }
  var onSleepStatus: ((SleepGuardStatus) -> Void)? {
    didSet { onSleepStatus?(sleepStatus) }
  }

  /// The same rule the live backend applies: managed server, listening, policy on.
  private var shouldAssert: Bool {
    sleepPolicy.isEnabled && snapshot.phase == .listening && snapshot.owner == .dshBar
  }

  func refreshExternal() {}

  func redetect() -> DshLookup {
    .found(DshDetection(path: "/usr/local/bin/dsh", source: .localBin))
  }

  func preview(_ scene: DemoScene) {
    pending?.cancel()
    stopTicking()
    startedAt = scene == .listening ? Date() : nil
    var next = Fixtures.snapshot(for: scene, copy: Copy(language: language), port: port)
    next.profile = profile
    if scene == .listening { next.uptime = 761 }
    publish(next)
    if scene == .listening { startTicking() }
  }

  func shutdown() {
    pending?.cancel()
    stopTicking()
  }

  // MARK: - Environment (fixtures)

  /// A plausible report, so the settings window can be reviewed without a shell.
  private(set) var environmentReport: EnvironmentReport? = EnvironmentReport(
    source: .interactiveShell,
    variableCount: 97,
    pathHead: "~/.nvm/versions/node/v24.22.2/bin:/opt/homebrew/bin:/usr/bin",
    nodePath: "~/.nvm/versions/node/v24.22.2/bin/node",
    nodeVersion: "v24.22.2",
    durationMs: 412,
    resolvedAt: Date()
  )
  var onEnvironment: ((EnvironmentReport?) -> Void)?

  func rereadEnvironment() {
    onEnvironment?(environmentReport)
  }

  func prepareHandoff() {}

  // MARK: - Internals

  var currentScene: DemoScene? {
    switch snapshot.phase {
    case .unavailable: return .unavailable
    case .stopped: return .stopped
    case .starting: return .starting
    case .stopping: return .stopping
    case .failed: return snapshot.failure?.port == nil ? .failedExit : .failedPort
    case .listening: return snapshot.owner == .external ? .listeningExternal : .listening
    }
  }

  /// One rule for the fixture build as well: what the footer claims is derived
  /// from the scene and the policy, never copied from the scene alone.
  private func publish(_ scene: HarnessSnapshot) {
    var out = scene
    out.awake = sleepPolicy.isEnabled && out.phase == .listening && out.owner == .dshBar
    snapshot = out
    launchURL = out.phase == .listening && out.owner == .dshBar && out.hasLaunchURL
      ? "http://\(out.address)/?token=demo"
      : nil
    onSnapshot?(out)
    onSleepStatus?(sleepStatus)
  }

  private func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
    let item = DispatchWorkItem(block: work)
    pending = item
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
  }

  private func startTicking() {
    stopTicking()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let started = self.startedAt else { return }
        var next = self.snapshot
        next.uptime = Date().timeIntervalSince(started) + 761
        self.publish(next)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private func stopTicking() {
    ticker?.invalidate()
    ticker = nil
  }
}
