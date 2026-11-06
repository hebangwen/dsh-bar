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
  /// `LogFileWriter` serialises every append behind its own lock, so the shell and
  /// report work can write from a background queue while the main actor reads.
  nonisolated private let writer = LogFileWriter()
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
  private(set) var environmentReport: EnvironmentReport?
  var onEnvironment: ((EnvironmentReport?) -> Void)?
  var sleepStatus: SleepGuardStatus { sleepGuard.status }
  var onSleepStatus: ((SleepGuardStatus) -> Void)?

  /// Holds the `caffeinate -i -w <dsh pid>` that keeps the machine awake while the
  /// server is serving. Owned here because this is where the child pid is known.
  private let sleepGuard = SleepGuard()
  /// `DSHBAR_SLEEP_POLICY` wins over the preference, for scripted runs.
  private let forcedSleepPolicy = SleepPolicy.forced(from: ProcessInfo.processInfo.environment)
  /// `DSHBAR_AUTO_RESTART=off` / `DSHBAR_NOTIFY=off` exist for the smoke tool: a
  /// scripted run should be able to prove the watchdog is silent when switched off.
  private var forcedAutoRestart: Bool? {
    switch ProcessInfo.processInfo.environment["DSHBAR_AUTO_RESTART"]?.lowercased() {
    case "0", "off", "false": return false
    case "1", "on", "true": return true
    default: return nil
    }
  }
  private var notificationsForced: Bool? {
    switch ProcessInfo.processInfo.environment["DSHBAR_NOTIFY"]?.lowercased() {
    case "0", "off", "false": return false
    case "1", "on", "true": return true
    default: return nil
    }
  }

  /// The notifier is handed in so the smoke tool can swap in one that only counts.
  let notifier: CrashNotifier
  var notificationPermission: NotificationPermission { notifier.permission }
  var onNotificationPermission: ((NotificationPermission) -> Void)?

  /// The flags the running child was actually started with. The panel draws this
  /// while listening, so changing Settings mid-run cannot make the readout claim an
  /// address the process is not on.
  private var launchedFlags: WebLaunchFlags?

  private var watchTimer: Timer?
  private var readyTimer: Timer?
  private var restartTimer: Timer?
  private var stopTimer: Timer?
  private var killTimer: Timer?
  private var uptimeTimer: Timer?

  init(
    language: UILanguage,
    preferences: BarPreferences,
    notifier: CrashNotifier = NotificationCenterClient.system
  ) {
    self.language = language
    self.preferences = preferences
    self.notifier = notifier
    var snapshot = Fixtures.snapshot(
      for: .stopped,
      copy: Copy(language: language),
      port: preferences.port
    )
    snapshot.profile = preferences.profile
    snapshot.lastRun = nil
    state = HarnessState(snapshot: snapshot)
    // The guard speaks from the main queue; its lines belong in the same log the
    // panel shows, next to dsh's own output.
    sleepGuard.onChange = { [weak self] status in
      guard let self else { return }
      self.onSleepStatus?(status)
      self.emit()
    }
    sleepGuard.onEvent = { [weak self] line in
      guard let self else { return }
      self.writer.note(line)
      self.append(line: "dsh bar: \(line)", stream: .err)
    }
    notifier.refreshPermission()
    // The permission is read once at launch and again when Settings opens; the
    // prompt itself is only ever raised by the user turning the switch on.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.notifier.refreshPermission()
        self.onNotificationPermission?(self.notifier.permission)
      }
    }
    startWatching()
    // The first Start should not pay for a shell launch, and a hung rc file must
    // not be able to block the click.
    warmEnvironment()
    pruneHandoffIfGone()
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
    let host = probeHost
    probeQueue.async { [weak self] in
      let portState = PortProbe.probe(host: host, port: port)
      // The process table and the port are both read here, off the main thread: the
      // handoff question is "is the pid in my note still the dsh on this port?".
      var verdict: HandoffVerdict = .noRecord
      if portState == .dsh, let record = HandoffStore.load(), record.port == port {
        let info = ExternalInstance.describe(pid: record.pid)
        let inspection = HandoffInspection(
          pidAlive: info.map { ExternalInstance.isAlive($0) } ?? false,
          command: info?.command,
          group: info?.group,
          portServesDsh: true
        )
        verdict = HandoffVerifier.verify(record, inspection: inspection)
        if !verdict.isUsable {
          // A claim that no longer matches the process table is worth forgetting:
          // keeping it would make every probe re-read `ps` for a pid that is gone.
          HandoffStore.clear()
          self?.writer.note("handoff record dropped: \(verdict)")
        }
      } else if portState == .free, let record = HandoffStore.load(), record.port == port {
        HandoffStore.clear()
      }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self?.observe(portState, port: port, handoff: verdict)
        }
      }
    }
  }

  private func observe(_ portState: PortState, port: Int, handoff: HandoffVerdict = .noRecord) {
    guard port == state.snapshot.port else { return }
    switch (state.snapshot.phase, portState) {
    case (.stopped, .dsh):
      dispatch(handoff.isUsable ? .observedHandoff(port: port) : .observedExternal(port: port))
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
    notifier.clearDelivered()
    invalidateTimers()
    // Before the process goes: the assertion is about a server that is about to
    // stop, and nothing should be left holding the machine awake.
    sleepGuard.release()
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
    let previous = state.snapshot
    let (next, commands) = HarnessReducer.reduce(
      state,
      event,
      language: language,
      autoRestart: forcedAutoRestart ?? preferences.autoRestart
    )
    state = next
    launchURL = state.launchURL
    if event == .restartDue || event == .restartAbandoned {
      writer.note("watchdog: \(event) → \(state.snapshot.phase)")
    }
    for command in commands {
      perform(command)
    }
    emit()
    announce(previous: previous, next: state.snapshot)
  }

  /// The notification side effect, decided by `NotificationPolicy`: a transition
  /// out of a live state, never a state someone reopened the panel to look at.
  private func announce(previous: HarnessSnapshot, next: HarnessSnapshot) {
    guard let event = NotificationPolicy.event(previous: previous, next: next) else { return }
    if let attempts = state.gaveUpAfter {
      state.gaveUpAfter = nil
      writer.note("watchdog: gave up after \(attempts) attempt(s)")
      notifier.post(.restartGaveUp(attempts: attempts), copy: Copy(language: language), enabled: notificationsEnabled)
      return
    }
    notifier.post(event, copy: Copy(language: language), enabled: notificationsEnabled)
  }

  private var notificationsEnabled: Bool {
    notificationsForced ?? preferences.notify
  }

  private func emit() {
    // Reconcile before publishing: the footer's `awake` word has to describe the
    // assertion state this snapshot is drawn with, not the previous one.
    syncSleepGuard()
    state.snapshot.log = log.lines
    state.snapshot.awake = sleepGuard.status.isAsserting
    // The footer's LAN/TLS words and the readout's address describe the process,
    // not the settings page: while serving, the flags it was spawned with win.
    let flags = effectiveFlags
    state.snapshot.bindHost = flags.host
    state.snapshot.secure = flags.usesTLS
    onSnapshot?(state.snapshot)
  }

  /// The assertion exists exactly while a server this app started is listening.
  ///
  /// The pid matters: `caffeinate -w` ties the assertion to that process, so a dsh
  /// that dies takes the assertion with it even if this app never gets to react.
  private var effectiveFlags: WebLaunchFlags {
    if state.snapshot.phase == .listening, let launchedFlags { return launchedFlags }
    return preferences.launchFlags
  }

  /// Where the port probe should look: the bind address when one is configured,
  /// loopback otherwise. A server bound to one LAN interface does not answer on
  /// 127.0.0.1, so probing the wrong address would report a busy port as free.
  private var probeHost: String {
    effectiveFlags.host ?? "127.0.0.1"
  }

  /// Called after every dispatch, which includes the once-a-second uptime tick —
  /// `SleepGuardPlan` returns `noop` in the steady state, so that costs a lock and
  /// two comparisons.
  private func syncSleepGuard() {
    let watched = SleepGuardTarget.watchedPID(
      phase: state.snapshot.phase,
      owner: state.snapshot.owner,
      child: child?.pid
    )
    sleepGuard.reconcile(policy: forcedSleepPolicy ?? preferences.sleepPolicy, watching: watched)
  }

  private func perform(_ command: HarnessCommand) {
    switch command {
    case .writeLogSeparator:
      log.reset()
      writer.separator(port: state.snapshot.port, profile: state.snapshot.profile)

    case .probePort(let port):
      let host = probeHost
      probeQueue.async { [weak self] in
        guard let self else { return }
        let portState = PortProbe.probe(host: host, port: port)
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

    case .scheduleRestart(let delay):
      restartTimer?.invalidate()
      let timer = Timer(timeInterval: TimeInterval(delay), repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.dispatch(.restartDue)
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      restartTimer = timer
      writer.note("watchdog: \(state.snapshot.restartAttempt ?? 1)/\(CrashWatchdog.maxAttempts) in \(delay)s")

    case .cancelRestart:
      restartTimer?.invalidate()
      restartTimer = nil

    case .restartNow:
      restartTimer?.invalidate()
      restartTimer = nil
      // The whole probe → spawn path, exactly as a hand start: a port that came
      // back is a different answer than the one that failed a second ago.
      perform(.probePort(state.snapshot.port))
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

    // Optional flags are validated with the same value type Settings uses, so a
    // wildcard host or a certificate that moved fails here with a sentence instead
    // of inside dsh thirty seconds later.
    let flags = preferences.launchFlags
    if let problem = flags.firstProblem() {
      let detail = Copy(language: language).launchFlagProblem(problem)
      failStart(
        HarnessFailure(kind: .launchFlags(problem), detail: detail),
        note: "not spawning: \(detail)"
      )
      return
    }
    let arguments = flags.arguments(profile: state.snapshot.profile, port: port)

    // The two launch paths are checked before anything is spawned: `posix_spawn`
    // would otherwise fail with a chdir error that reads like a broken binary.
    let target = LaunchTarget.resolve(preferences)
    if let problem = target.workspaceProblem {
      failStart(
        HarnessFailure(kind: .workspaceMissing(path: problem.path), detail: describe(problem)),
        note: "not spawning: the working directory is unusable — \(problem.path)"
      )
      return
    }
    if let problem = target.dshHomeProblem {
      failStart(
        HarnessFailure(kind: .dshHomeMissing(path: problem.path), detail: describe(problem)),
        note: "not spawning: DSH_HOME is unusable — \(problem.path)"
      )
      return
    }
    if let dshHome = target.dshHome, !ensureDirectory(dshHome) {
      failStart(
        HarnessFailure(kind: .dshHomeMissing(path: dshHome), detail: "could not create the directory"),
        note: "not spawning: could not create DSH_HOME — \(dshHome)"
      )
      return
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
    for (key, value) in target.environmentOverlay {
      values[key] = value
    }
    let cwdNote = target.workingDirectory.map { LaunchTarget.shortPath($0) } ?? "dsh default"
    let homeNote: String
    switch (target.dshHome, target.dshHomeOrigin) {
    case (nil, _): homeNote = "from the login shell"
    case (let path?, .ownDefault): homeNote = "\(LaunchTarget.shortPath(path)) (default)"
    case (let path?, _): homeNote = LaunchTarget.shortPath(path)
    }
    writer.note("launch paths: cwd \(cwdNote) · DSH_HOME \(homeNote)")
    append(line: "dsh bar: cwd \(cwdNote) · DSH_HOME \(homeNote)", stream: .err)
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
        environment: values,
        workingDirectory: target.workingDirectory
      )
      self.child = child
      self.launchedFlags = flags
      writer.note("spawned \(detection.path) \(arguments.joined(separator: " ")) pid=\(child.pid)")
      if !flags.isDefault {
        writer.note("launch flags: host \(flags.host ?? "dsh default") · tls \(flags.usesTLS ? "on" : "off") · patches \(flags.patches.count)")
      }

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
          self.launchedFlags = nil
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
            HandoffStore.clear()
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

  // MARK: - Notifications

  func refreshNotificationPermission() {
    notifier.refreshPermission()
    // The read is asynchronous by nature; the settings row asks again a moment
    // later rather than showing a spinner for a value it already has.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.onNotificationPermission?(self.notifier.permission)
      }
    }
  }

  func requestNotificationAuthorization() {
    notifier.requestAuthorization()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.onNotificationPermission?(self.notifier.permission)
      }
    }
  }

  func clearDeliveredNotifications() {
    notifier.clearDelivered()
  }

  // MARK: - Output

  private func append(line: String, stream: LogStream) {
    // One redaction point for both consumers: the four lines the panel shows and
    // the file on disk. `LaunchOutput` already read the raw line for its token.
    let safe = LogRedaction.redact(line)
    log.append(safe, stream: stream)
    writer.write(safe, stream: stream)
  }

  // MARK: - Environment

  /// The one place a shell is asked. Everything else reads the cache or the report.
  nonisolated private func resolveEnvironmentNow(log: Bool) -> (values: [String: String], source: LoginShellEnvironment.Source, durationMs: Int) {
    let started = Date()
    let resolved = LoginShellEnvironment.resolve()
    let duration = Int((Date().timeIntervalSince(started) * 1000).rounded())
    if log {
      switch resolved.source {
      case .process:
        writer.note("no shell answered; falling back to the process environment (PATH: \(resolved.values["PATH"] ?? "empty")), \(duration) ms")
      case .interactiveShell:
        writer.note("environment from the interactive login shell, \(duration) ms")
      case .loginShell:
        writer.note("environment from the login shell (no rc), \(duration) ms; ~/.zshrc exports are missing")
      }
    }
    return (resolved.values, resolved.source, duration)
  }

  /// Asks the interactive login shell once, off the main thread. `zsh -lic` is the
  /// only shell that reads `~/.zshrc`, which is where nvm puts `node` — a
  /// GUI-launched app inherits neither.
  private func warmEnvironment() {
    guard !isWarmingEnvironment else { return }
    isWarmingEnvironment = true
    probeQueue.async { [weak self] in
      guard let self else { return }
      let resolved = self.resolveEnvironmentNow(log: false)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.isWarmingEnvironment = false
          self.environment = resolved.values
          self.environmentSource = resolved.source
          self.environmentDate = Date()
          self.publishEnvironmentReport(
            values: resolved.values,
            source: resolved.source,
            durationMs: resolved.durationMs
          )
        }
      }
    }
  }

  /// The settings "Read again" button: ignore the 60-second cache and ask the shell
  /// now. Runs off the main thread so a slow `.zshrc` never freezes the window.
  func rereadEnvironment() {
    guard !isWarmingEnvironment else { return }
    isWarmingEnvironment = true
    probeQueue.async { [weak self] in
      guard let self else { return }
      let resolved = self.resolveEnvironmentNow(log: true)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.isWarmingEnvironment = false
          self.environment = resolved.values
          self.environmentSource = resolved.source
          self.environmentDate = Date()
          self.publishEnvironmentReport(
            values: resolved.values,
            source: resolved.source,
            durationMs: resolved.durationMs
          )
        }
      }
    }
  }

  /// Publish the report, then fill in the node version when the shell's node can be
  /// asked. The version is decoration; the report is useful without it.
  private func publishEnvironmentReport(
    values: [String: String],
    source: LoginShellEnvironment.Source,
    durationMs: Int
  ) {
    let report = EnvironmentReport.make(values: values, source: source, durationMs: durationMs)
    environmentReport = report
    onEnvironment?(report)
    guard let node = report.nodePath else { return }
    probeQueue.async { [weak self] in
      let version = Self.nodeVersion(at: node)
      guard let version else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, var current = self.environmentReport, current.source == source else { return }
          current.nodeVersion = version
          self.environmentReport = current
          self.onEnvironment?(current)
        }
      }
    }
  }

  nonisolated private static func nodeVersion(at path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let text = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (text?.isEmpty ?? true) ? nil : text
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
    let resolved = resolveEnvironmentNow(log: true)
    environment = resolved.values
    environmentSource = resolved.source
    environmentDate = Date()
    if let source = environmentSource {
      publishEnvironmentReport(values: resolved.values, source: source, durationMs: resolved.durationMs)
    }
    return resolved.values
  }

  // MARK: - Launch paths

  /// One sentence for the panel's diagnosis block.
  private func describe(_ problem: LaunchPathProblem) -> String {
    switch problem {
    case .relative: return "relative path"
    case .notDirectory: return "not a folder"
    case .missing: return "no such folder"
    }
  }

  /// `mkdir -p` for DSH_HOME: dsh creates its own state directory on first boot, and
  /// the app passes an explicit path only because the user asked for one.
  private func ensureDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
      return isDirectory.boolValue
    }
    do {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
      return true
    } catch {
      writer.note("mkdir \(path) failed: \(error)")
      return false
    }
  }

  /// Refuse the launch before `posix_spawn` can turn a bad path into a confusing
  /// binary error.
  private func failStart(_ failure: HarnessFailure, note: String) {
    writer.note(note)
    append(line: "dsh bar: \(note)", stream: .err)
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.dispatch(.spawnFailed(failure))
      }
    }
  }

  // MARK: - Handoff

  /// A record from a quit that kept the server alive. Only the part that can be
  /// decided without touching the process table is done here: the rest happens when
  /// the port watcher actually sees a dsh.
  private func pruneHandoffIfGone() {
    guard let record = HandoffStore.load() else { return }
    probeQueue.async { [weak self] in
      let state = PortProbe.probe(port: record.port)
      guard state == .free else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          // Nothing on that port: the kept server is gone, so the note would be a lie.
          HandoffStore.clear()
          self?.writer.note("handoff record for port \(record.port) is stale; dropped")
        }
      }
    }
  }

  /// Keep the running server alive across this quit, and write down enough for the
  /// next launch to recognise it. Never signals anything.
  func prepareHandoff() {
    // The app is going away, so the power behaviour it introduced goes with it.
    // `-w` bounds the server's own lifetime from here on; if it is killed with
    // SIGKILL later, caffeinate still exits with it.
    sleepGuard.release()
    guard let child, state.snapshot.phase == .listening, state.snapshot.owner == .dshBar else {
      writer.note("handoff skipped: no managed server is listening")
      return
    }
    // `HandoffStore.save` masks the token before it writes: the note outlives the
    // run, and a bearer credential at rest is what 0.6.0 removed.
    let record = HandoffRecord(
      pid: child.pid,
      port: state.snapshot.port,
      startedAt: state.startedAt ?? Date(),
      launchURL: launchURL
    )
    HandoffStore.save(record)
    writer.note("handoff: keeping pid \(record.pid) on port \(record.port) after quit")
    // `detach()` first: dropping the last reference to a ChildProcess sends SIGTERM,
    // which would turn "keep it running" into "stop it a moment later".
    child.detach()
    self.child = nil
    invalidateTimers()
  }

  /// For a handoff test or a manual check: the record as this process would read it.
  var handoffRecord: HandoffRecord? { HandoffStore.load() }

  private func invalidateTimers() {
    restartTimer?.invalidate()
    restartTimer = nil
    watchTimer?.invalidate()
    readyTimer?.invalidate()
    stopTimer?.invalidate()
    killTimer?.invalidate()
    uptimeTimer?.invalidate()
    watchTimer = nil
    readyTimer = nil
    stopTimer = nil
    killTimer = nil
    uptimeTimer = nil
  }

}

/// The on-disk log the panel's "Open log" button opens.
///
/// Small, append-only, and rotated by hand: one file over 1 MB becomes `.1`. This
/// is deliberately not unified logging, because the user needs to read dsh's own
/// lines and copy them.
final class LogFileWriter: @unchecked Sendable {
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
    // A 0.5.0 log keeps every launch token it ever saw; the first launch on this
    // build rewrites the file (and its rotated sibling) with the values masked.
    scrubExistingTokens()
  }

  deinit {
    try? handle?.close()
  }

  func separator(port: Int, profile: String) {
    append("=== \(stamp()) start profile=\(profile) port=\(port == 0 ? "auto" : "\(port)") ===\n")
  }

  func note(_ text: String) {
    append("\(stamp())  [bar] \(LogRedaction.redact(text))\n")
  }

  func write(_ text: String, stream: LogStream) {
    append("\(LogBuffer.clock())  [\(stream.rawValue)] \(LogRedaction.redact(text))\n")
  }

  /// Mask tokens that an earlier build wrote. Idempotent: a clean file is left
  /// untouched, so this is one read per launch, not a rewrite per launch.
  private func scrubExistingTokens() {
    for candidate in [url, url.appendingPathExtension("1")] {
      guard
        let data = try? Data(contentsOf: candidate),
        let text = String(data: data, encoding: .utf8)
      else { continue }
      let cleaned = LogRedaction.redact(text)
      guard cleaned != text else { continue }
      try? handle?.close()
      handle = nil
      try? Data(cleaned.utf8).write(to: candidate, options: .atomic)
      written = cleaned.utf8.count
    }
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
