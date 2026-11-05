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
  private var environmentSource: LoginShellEnvironment.Source?
  private var isWarmingEnvironment = false

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
    // The first Start should not pay for a shell launch, and a hung rc file must
    // not be able to block the click.
    warmEnvironment()
  }

  // MARK: - HarnessBackend

  func update(_ preferences: BarPreferences) {
    self.preferences = preferences
    dispatch(.preferencesChanged(port: preferences.port, profile: preferences.profile))
  }

  func start(port: Int, profile: String) {
    // A child from a previous attempt may still be alive (it can ignore SIGTERM);
    // a second one would fight it for the same session store.
    if let child, child.isAlive { return }
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
    // Detection must not wait on a shell: it runs while the panel is drawn, and the
    // locator already finds dsh through nvm/Homebrew paths without a PATH.
    let values = environmentForDetection()
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
    // A child we own is not an external instance, even if the reducer has already
    // moved on (cancel, timeout) while the process is still alive.
    guard child == nil else { return }
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

    // The child inherits this process's TCC identity, so the grant has to be held
    // here — and re-acquired per spawn, because a bookmark resolved at launch can
    // be dropped by a TCC reset in between. When it is missing the start would fail
    // deep inside dsh with an unexplained `EPERM`, so say it here instead.
    let documents = DocumentsAccess.store
    _ = documents.startAccessing()
    let access = documents.snapshot(probe: documents.hasBookmark)
    // Probing an ungranted TCC folder is what raises the system sheet, so this only
    // reads when a bookmark says it may. Without one the line says what to do
    // instead of guessing that the read would fail.
    let folderNote: String?
    switch access.state {
    case .denied:
      folderNote = "read access to \(access.displayPath) was refused; dsh's default workspace lives there"
        + " — grant it in Settings › Folder access"
    case .notRequested:
      folderNote = "no folder grant stored for \(access.displayPath); dsh's default workspace lives there"
        + " — authorize it in Settings › Folder access"
    case .granted, .missing:
      folderNote = nil
    }
    if let folderNote {
      writer.note(folderNote)
      append(line: "dsh bar: \(folderNote)", stream: .err)
    }

    var values = currentEnvironment()
    // The `node` that matters is the one dsh was installed with, and it sits in the
    // same directory. Putting that directory first keeps `#!/usr/bin/env node` from
    // picking a different runtime — or, on a GUI launch, finding none at all.
    values["PATH"] = LoginShellEnvironment.runnablePath(
      forExecutable: detection.path,
      environment: values
    )
    let node = LoginShellEnvironment.nodePath(onPath: values["PATH"])
    let head = (values["PATH"] ?? "").split(separator: ":").prefix(3).joined(separator: ":")
    writer.note("spawn env: \(environmentSource?.rawValue ?? "unknown") · PATH head \(head) · node \(node ?? "missing")")

    if node == nil, DshLocator.isEnvNodeScript(at: detection.path) {
      let detail = "no node on PATH (\(head)…)"
      writer.note("not spawning: \(detail)")
      append(line: "dsh bar: \(detail)", stream: .err)
      DispatchQueue.main.async { [weak self] in
        self?.dispatch(.spawnFailed(HarnessFailure(kind: .nodeMissing, detail: detail)))
      }
      return
    }

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
        guard let self else { return }
        if self.state.snapshot.phase == .stopping {
          self.dispatch(.killTimedOut)
        } else if let child = self.child, child.isAlive {
          // `.cancel`, `.readyTimeout` and a launch-time port race also send
          // SIGTERM, but the reducer has already left `.stopping`, so it will
          // never ask for the escalation itself.
          child.kill()
        }
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
        guard let self, let child = self.child, child.isAlive else { return }
        child.kill()
        if self.state.snapshot.phase == .stopping {
          self.dispatch(.exited(code: nil, signal: SIGKILL))
        }
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
          if stopped {
            self.dispatch(.exited(code: 0, signal: nil))
          } else {
            // The port is still held. Reporting `.exited` here would claim a clean
            // stop, persist the port, and retry a start that cannot win.
            self.dispatch(.stopFailed(port: port, detail: detail))
          }
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

  /// Asks the interactive login shell once, off the main thread. `zsh -lic` is the
  /// only shell that reads `~/.zshrc`, which is where nvm puts `node` — a
  /// GUI-launched app inherits neither.
  private func warmEnvironment() {
    guard !isWarmingEnvironment else { return }
    isWarmingEnvironment = true
    probeQueue.async { [weak self] in
      let resolved = LoginShellEnvironment.resolve()
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          self.isWarmingEnvironment = false
          self.environment = resolved.values
          self.environmentSource = resolved.source
          self.environmentDate = Date()
        }
      }
    }
  }

  /// For the locator: whatever is cached, else the app's own environment, with a
  /// refresh kicked off in the background. Never blocks.
  private func environmentForDetection() -> [String: String] {
    if let environment { return environment }
    warmEnvironment()
    return ProcessInfo.processInfo.environment
  }

  /// For the spawn: blocks when the cache is cold, because a PATH without `node`
  /// is exactly the failure this whole path exists to prevent.
  private func currentEnvironment() -> [String: String] {
    if let environment, let environmentDate, Date().timeIntervalSince(environmentDate) < 60 {
      return environment
    }
    let resolved = LoginShellEnvironment.resolve()
    environment = resolved.values
    environmentSource = resolved.source
    environmentDate = Date()
    switch resolved.source {
    case .process:
      writer.note("no shell answered; falling back to the process environment (PATH: \(resolved.values["PATH"] ?? "empty"))")
    case .interactiveShell:
      writer.note("environment from the interactive login shell")
    case .loginShell:
      writer.note("environment from the login shell (no rc); ~/.zshrc exports are missing")
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
  private var written = 0
  private static let limit = 1_048_576

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
    openIfNeeded()
    guard let data = text.data(using: .utf8) else { return }
    try? handle?.write(contentsOf: data)
    written += data.count
    if written > Self.limit {
      rotateLocked()
    }
  }

  private func openIfNeeded() {
    guard handle == nil else { return }
    handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
  }

  private func rotateLocked() {
    try? handle?.close()
    handle = nil
    let rotated = url.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: rotated)
    try? FileManager.default.moveItem(at: url, to: rotated)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    written = 0
    openIfNeeded()
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
