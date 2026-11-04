import AppKit
import Foundation
import DshBarKit

/// The real controller: one `dsh --profile web` child, its output, and the
/// transitions of `HarnessReducer`.
///
/// Everything that can fail here fails into a `HarnessSnapshot` the panel already
/// knows how to draw, so the view never learns a second vocabulary.
@MainActor
final class LiveBackend: HarnessBackend {
  var onSnapshot: ((HarnessSnapshot) -> Void)?
  private(set) var launchURL: String?

  private let language: UILanguage
  private let writer = LogFileWriter()
  private let probeQueue = DispatchQueue(label: "dev.dsh.bar.probe", qos: .userInitiated)

  private var preferences: BarPreferences
  private var state: HarnessState
  private var log = LogBuffer(capacity: 40)
  private var child: ChildProcess?
  private var detection: DshDetection?
  private var environment: [String: String]?
  private var environmentDate: Date?

  private var watchTimer: Timer?
  private var readyTimer: Timer?
  private var stopTimer: Timer?
  private var killTimer: Timer?
  private var uptimeTimer: Timer?

  init(language: UILanguage, preferences: BarPreferences) {
    self.language = language
    self.preferences = preferences
    var snapshot = Fixtures.snapshot(
      for: .stopped,
      copy: Copy(language: language),
      port: preferences.port
    )
    snapshot.profile = preferences.profile
    snapshot.lastRun = nil
    state = HarnessState(snapshot: snapshot)
    startWatching()
  }

  // MARK: - HarnessBackend

  func start(port: Int, profile: String) {
    let normalizedPort = BarPreferences.normalizePort(port)
    let normalizedProfile = BarPreferences.normalizeProfile(profile)
    preferences.port = normalizedPort
    preferences.profile = normalizedProfile
    preferences.save()

    switch redetect() {
    case .missing(let searched):
      dispatch(.detectionFailed(searched: searched))
    case .found:
      dispatch(.start(port: normalizedPort, profile: normalizedProfile))
    }
  }

  func stop() {
    dispatch(.stopRequested)
  }

  func cancel() {
    dispatch(.cancel)
  }

  func redetect() -> DshLookup {
    let values = currentEnvironment()
    let lookup = DshLocator.resolve(
      explicit: preferences.binaryPath,
      pathEnv: values["PATH"],
      home: values["HOME"] ?? NSHomeDirectory(),
      environmentOverride: ProcessInfo.processInfo.environment[DshLocator.environmentKey]
    )
    switch lookup {
    case .found(let found):
      detection = found
      writer.note("using dsh at \(found.path) (\(found.source.rawValue))")
    case .missing:
      detection = nil
      writer.note("dsh not found on PATH or in nvm/Homebrew locations")
    }
    return lookup
  }

  /// Probe the configured port for a server this app does not own. Runs when the
  /// panel opens, after the port changes, and on a slow timer, so a `dsh web`
  /// started in a terminal appears in the panel by itself.
  func refreshExternal() {
    let phase = state.snapshot.phase
    guard phase == .stopped || (phase == .listening && state.snapshot.owner == .external) else {
      return
    }
    let port = state.snapshot.port
    guard (1...65535).contains(port) else { return }
    probeQueue.async { [weak self] in
      let portState = PortProbe.probe(port: port)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.observe(portState, port: port)
        }
      }
    }
  }

  private func observe(_ portState: PortState, port: Int) {
    guard port == state.snapshot.port else { return }
    switch (state.snapshot.phase, portState) {
    case (.stopped, .dsh):
      dispatch(.observedExternal(port: port))
    case (.listening, .free) where state.snapshot.owner == .external:
      dispatch(.observedFree(port: port))
    default:
      break
    }
  }

  private func startWatching() {
    watchTimer?.invalidate()
    let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshExternal()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    watchTimer = timer
  }

  func preview(_ scene: DemoScene) {
    // The live controller has no preview scenes; only the demo backend does.
  }

  /// Called when the app is quitting. SIGTERM first, then a short wait, because a
  /// killed dsh leaves a session store that the next boot has to repair.
  func shutdown() {
    watchTimer?.invalidate()
    readyTimer?.invalidate()
    stopTimer?.invalidate()
    killTimer?.invalidate()
    uptimeTimer?.invalidate()
    readyTimer = nil
    stopTimer = nil
    killTimer = nil
    uptimeTimer = nil
    guard let child else { return }
    child.terminate()
    let deadline = Date().addingTimeInterval(0.8)
    while child.isAlive, Date() < deadline {
      usleep(50_000)
    }
    if child.isAlive {
      child.kill()
    }
  }

  // MARK: - Dispatch

  private func dispatch(_ event: HarnessEvent) {
    let (next, commands) = HarnessReducer.reduce(state, event, language: language)
    state = next
    launchURL = state.launchURL
    for command in commands {
      perform(command)
    }
    emit()
  }

  private func emit() {
    state.snapshot.log = log.lines
    onSnapshot?(state.snapshot)
  }

  private func perform(_ command: HarnessCommand) {
    switch command {
    case .writeLogSeparator:
      log.reset()
      writer.separator(port: state.snapshot.port, profile: state.snapshot.profile)

    case .probePort(let port):
      probeQueue.async { [weak self] in
        guard let self else { return }
        let portState = PortProbe.probe(port: port)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            self.dispatch(.portChecked(portState, port: port))
          }
        }
      }

    case .spawn(let port):
      spawn(port: port)

    case .armReadyTimeout(let seconds):
      readyTimer?.invalidate()
      let timer = Timer(timeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.dispatch(.readyTimeout(seconds: seconds))
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      readyTimer = timer

    case .disarmReadyTimeout:
      readyTimer?.invalidate()
      readyTimer = nil

    case .startUptime:
      startUptime()

    case .stopUptime:
      uptimeTimer?.invalidate()
      uptimeTimer = nil

    case .terminate:
      if let child {
        child.terminate()
        armStopTimeout()
      }

    case .kill:
      child?.kill()

    case .stopExternal(let port):
      stopExternal(port: port)
    }
  }

  // MARK: - Spawning

  private func spawn(port: Int) {
    guard let detection else {
      DispatchQueue.main.async { [weak self] in
        self?.dispatch(.spawnFailed(HarnessFailure(kind: .binaryMissing)))
      }
      return
    }

    var arguments = ["--profile", state.snapshot.profile, "--no-open"]
    if port != 0 {
      arguments.append(contentsOf: ["--port", "\(port)"])
    }

    let values = currentEnvironment()
    do {
      let child = try ChildProcess(
        executable: detection.path,
        arguments: arguments,
        environment: values
      )
      self.child = child
      writer.note("spawned \(detection.path) \(arguments.joined(separator: " ")) pid=\(child.pid)")

      child.onLine = { [weak self] stream, text in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.append(line: text, stream: stream)
          self.dispatch(.launch(LaunchOutput.classify(text)))
        }
      }

      child.onExit = { [weak self] code, signal in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.child = nil
          self.stopTimer?.invalidate()
          self.stopTimer = nil
          self.killTimer?.invalidate()
          self.killTimer = nil
          self.dispatch(.exited(code: code, signal: signal))
        }
      }
    } catch {
      let detail = "\(error)"
      writer.note("spawn failed: \(detail)")
      DispatchQueue.main.async { [weak self] in
        self?.dispatch(.spawnFailed(HarnessFailure(kind: .binaryMissing, detail: detail)))
      }
    }
  }

  // MARK: - Stopping

  private func armStopTimeout() {
    stopTimer?.invalidate()
    let timer = Timer(timeInterval: TimeInterval(HarnessReducer.stopGrace), repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.state.snapshot.phase == .stopping else { return }
        self.dispatch(.killTimedOut)
        self.armKillTimeout()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    stopTimer = timer
  }

  /// If SIGKILL somehow does not take the process down, the panel must stop
  /// claiming to be stopping.
  private func armKillTimeout() {
    killTimer?.invalidate()
    let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.state.snapshot.phase == .stopping else { return }
        self.child?.kill()
        self.dispatch(.exited(code: nil, signal: SIGKILL))
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    killTimer = timer
  }

  private func stopExternal(port: Int) {
    probeQueue.async { [weak self] in
      guard let self else { return }
      var stopped = false
      var detail = "no listener found on port \(port)"
      if let pid = ExternalInstance.listeningPID(port: port) {
        if let info = ExternalInstance.describe(pid: pid), ExternalInstance.canStop(info) {
          stopped = ExternalInstance.stop(info)
          detail = stopped
            ? "stopped the dsh listening on \(port) (pid \(pid))"
            : "the dsh on \(port) (pid \(pid)) ignored SIGTERM and SIGKILL"
        } else {
          detail = "pid \(pid) on port \(port) is not a dsh this app may stop"
        }
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.writer.note(detail)
          self.append(line: detail, stream: .err)
          self.dispatch(.exited(code: stopped ? 0 : nil, signal: stopped ? nil : SIGTERM))
        }
      }
    }
  }

  // MARK: - Clock

  private func startUptime() {
    uptimeTimer?.invalidate()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.dispatch(.tick)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    uptimeTimer = timer
  }

  // MARK: - Output

  private func append(line: String, stream: LogStream) {
    log.append(line, stream: stream)
    writer.write(line, stream: stream)
  }

  // MARK: - Environment

  /// The login shell is the only place PATH includes nvm's node; it costs about
  /// ten milliseconds, so it is re-read per launch and cached for a minute.
  private func currentEnvironment() -> [String: String] {
    if let environment, let environmentDate, Date().timeIntervalSince(environmentDate) < 60 {
      return environment
    }
    let resolved = LoginShellEnvironment.resolve()
    environment = resolved.values
    environmentDate = Date()
    if resolved.source == .process {
      writer.note("login shell environment unavailable; falling back to the process environment")
    }
    return resolved.values
  }
}

/// The on-disk log the panel's "Open log" button opens.
///
/// Small, append-only, and rotated by hand: one file over 1 MB becomes `.1`. This
/// is deliberately not unified logging, because the user needs to read dsh's own
/// lines and copy them.
final class LogFileWriter {
  let url: URL
  private let lock = NSLock()
  private var handle: FileHandle?

  init(url: URL = DshBarPaths.logFile) {
    self.url = url
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    rotateIfNeeded()
  }

  deinit {
    try? handle?.close()
  }

  func separator(port: Int, profile: String) {
    append("=== \(stamp()) start profile=\(profile) port=\(port == 0 ? "auto" : "\(port)") ===\n")
  }

  func note(_ text: String) {
    append("\(stamp())  [bar] \(text)\n")
  }

  func write(_ text: String, stream: LogStream) {
    append("\(LogBuffer.clock())  [\(stream.rawValue)] \(text)\n")
  }

  private func append(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    if handle == nil {
      handle = try? FileHandle(forWritingTo: url)
      _ = try? handle?.seekToEnd()
    }
    guard let data = text.data(using: .utf8) else { return }
    try? handle?.write(contentsOf: data)
  }

  private func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: Date())
  }

  private func rotateIfNeeded() {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    guard size > 1_048_576 else { return }
    let rotated = url.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: rotated)
    try? FileManager.default.moveItem(at: url, to: rotated)
    FileManager.default.createFile(atPath: url.path, contents: nil)
  }
}
