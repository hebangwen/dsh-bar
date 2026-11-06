import AppKit
import Darwin
import DshBarKit
import Foundation

/// Dependency-free checks for the value layer: copy, state predicates, fixtures
/// and the menu bar glyphs.
///
/// This machine has the Command Line Tools only, which do not ship XCTest, so
/// the assertions live in a normal executable: `swift run dshbar-check` exits
/// non-zero on the first failure list and needs nothing but the Swift toolchain.

@MainActor
final class Checks {
  private var failures: [String] = []
  private var count = 0

  func check(_ condition: Bool, _ message: String) {
    count += 1
    if !condition { failures.append(message) }
  }

  func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    count += 1
    if actual != expected {
      failures.append("\(message) — expected \(expected), got \(actual)")
    }
  }

  func report() -> Int32 {
    if failures.isEmpty {
      print("✓ \(count) checks passed")
      return 0
    }
    print("✗ \(failures.count) of \(count) checks failed")
    for failure in failures { print("  · \(failure)") }
    return 1
  }
}

@MainActor
func runChecks() -> Int32 {
  let checks = Checks()
  let en = Copy(language: .en)
  let zh = Copy(language: .zhHans)

  // MARK: Copy — state words

  checks.equal(en.stateWord(.listening), "Listening", "en listening")
  checks.equal(zh.stateWord(.listening), "正在监听", "zh listening")
  checks.equal(en.stateWord(.failed), "Couldn’t start", "en failed uses a typographic apostrophe")
  checks.equal(zh.stateWord(.stopped), "未运行", "zh stopped")
  checks.equal(en.stateWord(.unavailable), "dsh not found", "en unavailable")

  // MARK: Copy — formatting

  checks.equal(en.duration(9), "up 9s", "en seconds")
  checks.equal(en.duration(761), "up 12m 41s", "en minutes")
  checks.equal(en.duration(3725), "up 1h 2m", "en hours")
  checks.equal(zh.duration(9), "已运行 9 秒", "zh seconds")
  checks.equal(zh.duration(761), "已运行 12 分 41 秒", "zh minutes")
  checks.equal(zh.duration(3725), "已运行 1 小时 2 分", "zh hours")
  checks.equal(en.duration(-5), "up 0s", "duration never goes negative")

  // MARK: Copy — diagnosis

  let portText = en.diagnosis(HarnessFailure(kind: .portInUse(port: 3099)))
  checks.check(portText.title.contains("3099"), "port diagnosis names the port")
  checks.check(portText.body.contains("free port"), "port diagnosis suggests a free port")
  checks.check(
    zh.diagnosis(HarnessFailure(kind: .exited(code: 1))).title.contains("退出码 1"),
    "exit diagnosis carries the code"
  )

  // MARK: Copy — confirmations

  let external = HarnessSnapshot(phase: .listening, owner: .external)
  checks.equal(en.secondaryLabel(external), "Stop", "stop label before confirming")
  checks.equal(
    en.withStopConfirmation(true).secondaryLabel(external),
    "Stop for sure?",
    "stop label while confirming"
  )
  checks.equal(en.copyLink, "Copy link", "copy label")
  checks.equal(en.withCopyConfirmation(true).copyLink, "Copied", "copy confirmation label")
  checks.equal(en.primaryLabel(external), "Open in browser", "external primary action")
  checks.equal(
    en.primaryLabel(HarnessSnapshot(phase: .listening, owner: .dshBar)),
    "Open web GUI",
    "owned primary action"
  )

  // MARK: Language selection

  checks.equal(UILanguage.matching(preferred: ["zh-Hans-CN", "en-US"]), .zhHans, "zh preference")
  checks.equal(UILanguage.matching(preferred: ["en-GB"]), .en, "en preference")
  checks.equal(UILanguage.matching(preferred: ["fr-FR"]), .en, "unknown locale falls back to en")

  // MARK: Snapshot predicates

  for phase in [HarnessPhase.stopped, .starting, .stopping, .unavailable] {
    checks.check(!HarnessSnapshot(phase: phase).showsLog, "\(phase) must not show the log")
    checks.check(!HarnessSnapshot(phase: phase).offersStop, "\(phase) must not offer stop")
    checks.check(!HarnessSnapshot(phase: phase).canOpen, "\(phase) must not offer open")
  }
  checks.check(HarnessSnapshot(phase: .listening, log: Fixtures.log()).showsLog, "listening shows log")
  checks.check(HarnessSnapshot(phase: .failed).showsLog, "failed shows log")
  checks.check(HarnessSnapshot(phase: .listening).offersStop, "listening offers stop")
  checks.check(HarnessSnapshot(phase: .listening).canOpen, "listening can open")
  checks.check(!HarnessSnapshot(phase: .listening, owner: .dshBar).needsStopConfirmation, "owned stop is direct")
  checks.check(external.needsStopConfirmation, "external stop needs confirmation")
  checks.equal(
    HarnessSnapshot(phase: .listening, host: "127.0.0.1", port: 3099).address,
    "127.0.0.1:3099",
    "address follows host and port"
  )

  // MARK: Fixtures

  let expected: [DemoScene: HarnessPhase] = [
    .unavailable: .unavailable,
    .stopped: .stopped,
    .starting: .starting,
    .listening: .listening,
    .listeningExternal: .listening,
    .stopping: .stopping,
    .failedPort: .failed,
    .failedExit: .failed,
    .failedWorkspace: .failed,
    .listeningHandoff: .listening,
    .listeningLAN: .listening,
    .failedFlags: .failed,
    .restarting: .restarting,
  ]
  for scene in DemoScene.allCases {
    checks.equal(Fixtures.snapshot(for: scene, copy: en).phase, expected[scene] ?? .failed, "\(scene) phase")
  }
  let listening = Fixtures.snapshot(for: .listening, copy: en)
  checks.check(listening.uptime != nil, "listening fixture has uptime")
  checks.check(!listening.log.isEmpty, "listening fixture has output")
  let externalFixture = Fixtures.snapshot(for: .listeningExternal, copy: en)
  checks.equal(externalFixture.owner, .external, "external fixture owner")
  checks.check(externalFixture.uptime == nil, "external fixture has no uptime")
  checks.check(!externalFixture.hasLaunchURL, "external fixture has no launch token")
  checks.equal(
    Fixtures.snapshot(for: .failedPort, copy: en).failure?.port,
    3080,
    "port failure names the port"
  )

  // MARK: Preferences

  checks.equal(BarPreferences.normalizePort(0), 0, "port 0 means auto")
  checks.equal(BarPreferences.normalizePort(3099), 3099, "port passes through")
  checks.equal(BarPreferences.normalizePort(65535), 65535, "highest port is valid")
  checks.equal(BarPreferences.normalizePort(65536), 3080, "port above range falls back")
  checks.equal(BarPreferences.normalizePort(-1), 3080, "negative port falls back")
  checks.equal(BarPreferences.normalizeProfile("  "), "web", "blank profile falls back")
  checks.equal(BarPreferences.normalizeProfile(" tui "), "tui", "profile is trimmed")
  checks.equal(BarPreferences.normalizeBinaryPath("   "), nil, "blank path is nil")

  let suite = "dev.dsh.bar.check"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let saved = BarPreferences(binaryPath: "/opt/homebrew/bin/dsh", port: 3099, profile: "tui")
  saved.save(to: defaults)
  checks.equal(BarPreferences.load(from: defaults), saved, "preferences round-trip")
  BarPreferences(port: 3080, profile: "web").save(to: defaults)
  checks.equal(BarPreferences.load(from: defaults).binaryPath, nil, "absent path stays nil")
  defaults.removePersistentDomain(forName: suite)

  // MARK: Locator

  let candidates = DshLocator.candidates(
    explicit: "/custom/dsh",
    pathEnv: "/a/bin:/b/bin",
    home: "/home/tester",
    nvmVersions: ["18.9.0", "24.22.2"],
    environmentOverride: "/env/dsh"
  )
  checks.equal(candidates.first?.path, "/custom/dsh", "explicit path wins")
  checks.equal(candidates.first?.source, .setting, "explicit path is labelled")
  checks.equal(candidates[1].source, .environment, "environment override is second")
  checks.check(candidates.contains { $0.path == "/a/bin/dsh" }, "PATH dirs are searched")
  let nvmPaths = candidates.filter { $0.source == .nvm }.map(\.path)
  checks.equal(nvmPaths.first, "/home/tester/.nvm/versions/node/24.22.2/bin/dsh", "newest nvm first")
  checks.equal(candidates.last?.source, .localBin, "local bin is the last resort")
  checks.equal(
    DshLocator.candidates(explicit: "/a/bin/dsh", pathEnv: "/a/bin", home: "/h").count,
    3,
    "duplicate paths collapse"
  )
  checks.equal(
    DshLocator.sortVersions(["18.9.0", "9.0.0", "24.22.2"]),
    ["24.22.2", "18.9.0", "9.0.0"],
    "versions sort numerically"
  )
  let lookup = DshLocator.resolve(
    explicit: "/nonexistent/dsh",
    pathEnv: "/nonexistent",
    home: "/nonexistent"
  )
  if case let .missing(searched) = lookup {
    checks.check(searched.contains("/nonexistent/dsh"), "missing lookup lists what it tried")
  } else {
    checks.check(false, "missing lookup must not find anything")
  }

  // MARK: Login shell environment

  let raw = Data("PATH=/usr/bin\0HOME=/Users/t\0DSH_SESSION_ID=abc\0DSH_HOME=/Users/t/.dsh\0DSHBAR_DEMO=1\0PWD=/tmp\0EMPTY=\0WEIRD=a=b\0".utf8)
  let parsed = LoginShellEnvironment.parse(raw)
  checks.equal(parsed["PATH"], "/usr/bin", "env -0 parses PATH")
  checks.equal(parsed["WEIRD"], "a=b", "value keeps its equals signs")
  checks.equal(parsed["EMPTY"], "", "empty value survives")
  let sanitized = LoginShellEnvironment.sanitize(parsed, home: "/Users/t")
  checks.check(sanitized["DSH_SESSION_ID"] == nil, "session id is dropped")
  checks.equal(sanitized["DSH_HOME"], "/Users/t/.dsh", "DSH_HOME survives")
  checks.check(sanitized["DSHBAR_DEMO"] == nil, "app controls are dropped")
  checks.check(sanitized["PWD"] == nil, "PWD is dropped")
  let emptyEnv = LoginShellEnvironment.sanitize([:], home: "/Users/t", fallback: ["PATH": "/fallback"])
  checks.equal(emptyEnv["HOME"], "/Users/t", "HOME is filled in")
  checks.equal(emptyEnv["PATH"], "/fallback", "PATH falls back")

  // MARK: Launch line parsing

  let readyLine = "dsh web: http://127.0.0.1:3099/?token=deadbeef"
  guard case let .ready(parsedReady) = LaunchOutput.classify(readyLine) else {
    checks.check(false, "launch line must parse as ready")
    return checks.report()
  }
  checks.equal(parsedReady.port, 3099, "launch line port")
  checks.equal(parsedReady.host, "127.0.0.1", "launch line host")
  checks.equal(parsedReady.token, "deadbeef", "launch line token")
  checks.equal(parsedReady.url, "http://127.0.0.1:3099/?token=deadbeef", "launch line URL is verbatim")
  checks.equal(
    LaunchOutput.classify("  dsh web: http://127.0.0.1:3099/?token=deadbeef  "),
    .ready(parsedReady),
    "surrounding whitespace is tolerated"
  )
  checks.equal(
    LaunchOutput.parse("dsh web: http://127.0.0.1:3099/"),
    nil,
    "a URL without a token is not ready"
  )
  checks.equal(
    LaunchOutput.parse("dsh web: http://127.0.0.1:3099/?token=a&token=b"),
    nil,
    "two tokens are not ready"
  )
  checks.equal(
    LaunchOutput.classify("dsh web: opening the default browser; pass --no-open to disable"),
    .ignored,
    "the browser handoff line is ignored"
  )
  checks.equal(LaunchOutput.classify(""), .ignored, "empty line is ignored")
  checks.equal(
    LaunchOutput.classify("    Error: listen EADDRINUSE: address already in use 127.0.0.1:3099"),
    .portInUse(port: 3099),
    "EADDRINUSE names the port"
  )
  checks.equal(
    LaunchOutput.classify("Error: listen EADDRINUSE: address already in use [::1]:3098"),
    .portInUse(port: 3098),
    "IPv6 authority is parsed"
  )
  if case .startupFailed = LaunchOutput.classify("dsh: startup failed: 2 required plugins did not activate") {
    checks.check(true, "startup failure is classified")
  } else {
    checks.check(false, "startup failure is classified")
  }
  checks.equal(
    LaunchOutput.classify("(node:50256) [DSH_MOBILE_NETWORK_REFRESH] Warning: could not follow the current LAN address"),
    .ignored,
    "stderr noise stays noise"
  )

  // MARK: Port fingerprint

  let fence = "dsh web authentication required; reopen the URL printed by dsh web."
  checks.equal(PortProbe.classify(statusCode: 401, bodyHead: fence), .dsh, "401 fence is a dsh")
  checks.equal(PortProbe.classify(statusCode: 200, bodyHead: "<!doctype html>"), .other, "html is not a dsh")
  checks.equal(PortProbe.classify(statusCode: 401, bodyHead: "unauthorized"), .other, "other 401 is not a dsh")
  checks.equal(PortProbe.classify(statusCode: 0, bodyHead: "  " + fence), .dsh, "leading space still fingerprints")
  let response = PortProbe.splitResponse("HTTP/1.1 401 Unauthorized\r\nDate: now\r\n\r\n" + fence)
  checks.equal(response.status, 401, "status line parses")
  checks.equal(response.body, fence, "body follows the header block")
  checks.equal(PortProbe.splitResponse("garbage").status, 0, "garbage has no status")

  // MARK: Log buffer

  var log = LogBuffer(capacity: 3)
  for index in 1...5 {
    log.append("line \(index)")
  }
  checks.equal(log.lines.count, 3, "buffer keeps its capacity")
  checks.equal(log.lines.last?.text, "line 5", "buffer keeps the newest line")
  checks.equal(log.lines.first?.text, "line 3", "buffer drops the oldest line")
  checks.equal(log.lines.last?.id, 4, "line ids keep counting from zero")
  checks.check(LogBuffer.isEmphasized(readyLine), "launch line is emphasized")
  checks.check(LogBuffer.isEmphasized("Error: listen EADDRINUSE"), "errors are emphasized")
  checks.check(!LogBuffer.isEmphasized("(node:1) Warning: mobile access stays dormant"), "warnings stay quiet")
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  checks.equal(
    LogBuffer.clock(Date(timeIntervalSince1970: 0), calendar: calendar),
    "00:00:00",
    "clock is HH:mm:ss"
  )
  var longLog = LogBuffer(capacity: 2)
  longLog.append(String(repeating: "x", count: LogBuffer.maximumLineLength + 10))
  checks.check(
    (longLog.lines.first?.text.count ?? 0) <= LogBuffer.maximumLineLength + 1,
    "runaway lines are capped"
  )

  // MARK: Reducer — start and ready

  let t0 = Date(timeIntervalSince1970: 1_000)
  let (state, commands) = HarnessReducer.reduce(
    HarnessState(),
    .start(port: 3099, profile: "web"),
    language: .en
  )
  checks.equal(state.snapshot.phase, .starting, "start enters starting")
  checks.check(state.snapshot.busy, "starting is busy")
  checks.equal(state.snapshot.port, 3099, "start records the port")
  checks.equal(commands, [.writeLogSeparator, .probePort(3099)], "start probes before spawning")

  let (autoState, autoCommands) = HarnessReducer.reduce(
    HarnessState(),
    .start(port: 0, profile: "web"),
    language: .en
  )
  checks.equal(autoState.snapshot.phase, .starting, "auto port enters starting")
  checks.equal(
    autoCommands,
    [.writeLogSeparator, .spawn(port: 0), .armReadyTimeout(seconds: 30)],
    "auto port skips the probe"
  )

  let (freeState, freeCommands) = HarnessReducer.reduce(
    state,
    .portChecked(.free, port: 3099),
    language: .en
  )
  checks.equal(freeState.snapshot.phase, .starting, "a free port keeps starting")
  checks.equal(freeCommands, [.spawn(port: 3099), .armReadyTimeout(seconds: 30)], "free port spawns")

  let (busyState, busyCommands) = HarnessReducer.reduce(
    state,
    .portChecked(.other, port: 3099),
    language: .en
  )
  checks.equal(busyState.snapshot.phase, .failed, "an occupied port fails")
  checks.equal(busyState.snapshot.failure?.port, 3099, "occupied port names itself")
  checks.equal(busyCommands, [.disarmReadyTimeout], "occupied port cancels the timeout")

  let (externalState, _) = HarnessReducer.reduce(
    state,
    .portChecked(.dsh, port: 3099),
    language: .en
  )
  checks.equal(externalState.snapshot.phase, .listening, "an external dsh listens")
  checks.equal(externalState.snapshot.owner, .external, "external owner is recorded")
  checks.check(!externalState.snapshot.hasLaunchURL, "external dsh has no token")
  checks.check(!externalState.snapshot.busy, "listening is not busy")

  let report = LaunchReport(
    url: "http://127.0.0.1:53434/?token=abc",
    host: "127.0.0.1",
    port: 53434,
    token: "abc"
  )
  let (readyState, readyCommands) = HarnessReducer.reduce(
    HarnessReducer.reduce(state, .portChecked(.free, port: 0), language: .en).0,
    .launch(.ready(report)),
    language: .en,
    now: t0
  )
  checks.equal(readyState.snapshot.phase, .listening, "ready enters listening")
  checks.equal(readyState.snapshot.owner, .dshBar, "ready owner is the app")
  checks.equal(readyState.snapshot.port, 53434, "ready adopts the real port")
  checks.check(readyState.snapshot.hasLaunchURL, "ready has a launch URL")
  checks.equal(readyState.snapshot.uptime, 0, "ready starts uptime at zero")
  checks.equal(readyState.launchURL, report.url, "ready keeps the URL")
  checks.equal(readyCommands, [.disarmReadyTimeout, .startUptime], "ready stops waiting and ticks")
  let (againState, againCommands) = HarnessReducer.reduce(
    readyState,
    .launch(.ready(report)),
    language: .en,
    now: t0
  )
  checks.equal(againState, readyState, "a second launch line changes nothing")
  checks.equal(againCommands, [], "a second launch line runs nothing")

  let (tickState, _) = HarnessReducer.reduce(
    readyState,
    .tick,
    language: .en,
    now: t0.addingTimeInterval(12)
  )
  checks.equal(tickState.snapshot.uptime, 12, "tick counts seconds")

  // MARK: Reducer — failure paths

  let (raceState, raceCommands) = HarnessReducer.reduce(
    state,
    .launch(.portInUse(port: 3099)),
    language: .en
  )
  checks.equal(raceState.snapshot.phase, .failed, "a startup port race fails")
  checks.equal(raceState.snapshot.failure?.port, 3099, "the race keeps its port")
  checks.equal(raceCommands, [.disarmReadyTimeout, .terminate], "the race kills the child")

  let (timeoutState, timeoutCommands) = HarnessReducer.reduce(
    state,
    .readyTimeout(seconds: 30),
    language: .en
  )
  checks.equal(timeoutState.snapshot.phase, .failed, "timeout fails the start")
  if case .timeout(let seconds) = timeoutState.snapshot.failure?.kind {
    checks.equal(seconds, 30, "timeout carries its budget")
  } else {
    checks.check(false, "timeout carries its budget")
  }
  checks.equal(timeoutCommands, [.disarmReadyTimeout, .terminate], "timeout terminates the child")

  let (spawnFailState, _) = HarnessReducer.reduce(
    state,
    .spawnFailed(HarnessFailure(kind: .binaryMissing)),
    language: .en
  )
  checks.equal(spawnFailState.snapshot.phase, .failed, "spawn failure fails the start")
  checks.equal(spawnFailState.snapshot.failure?.kind, .binaryMissing, "spawn failure keeps its kind")

  let (crashState, crashCommands) = HarnessReducer.reduce(
    readyState,
    .exited(code: 1, signal: nil),
    language: .en
  )
  checks.equal(crashState.snapshot.phase, .restarting, "a crash after ready hands over to the watchdog")
  checks.equal(crashState.snapshot.failure?.kind, .exited(code: 1), "the crash keeps its code")
  checks.equal(crashState.snapshot.lastRun, "just now", "the crash records when it ran")
  checks.check(!crashState.snapshot.hasLaunchURL, "a crash loses the URL")
  checks.equal(
    crashCommands,
    [.stopUptime, .disarmReadyTimeout, .scheduleRestart(delay: 1)],
    "a crash stops the clock and schedules the first retry"
  )

  let (startFailState, _) = HarnessReducer.reduce(
    state,
    .exited(code: 1, signal: nil),
    language: .en
  )
  checks.equal(startFailState.snapshot.phase, .failed, "an exit while starting fails")

  // MARK: Reducer — stop, cancel, reset

  let (stoppingState, stoppingCommands) = HarnessReducer.reduce(
    readyState,
    .stopRequested,
    language: .en
  )
  checks.equal(stoppingState.snapshot.phase, .stopping, "stop enters stopping")
  checks.check(stoppingState.snapshot.busy, "stopping is busy")
  checks.check(stoppingState.intentionalStop, "stop is remembered as intentional")
  checks.check(stoppingCommands.contains(.terminate), "stop terminates the child")

  let (externalStopState, externalStopCommands) = HarnessReducer.reduce(
    externalState,
    .stopRequested,
    language: .en
  )
  checks.equal(externalStopState.snapshot.phase, .stopping, "an external stop enters stopping")
  checks.check(externalStopCommands.contains(.stopExternal(port: 3099)), "an external stop targets its pid")
  checks.check(!externalStopCommands.contains(.terminate), "an external stop has no child to signal")

  let (stoppedState, _) = HarnessReducer.reduce(
    stoppingState,
    .exited(code: 0, signal: nil),
    language: .en
  )
  checks.equal(stoppedState.snapshot.phase, .stopped, "an intentional exit is stopped")
  checks.equal(stoppedState.snapshot.failure, nil, "a clean stop has no failure")
  checks.equal(stoppedState.snapshot.lastRun, "just now", "a clean stop says just now")
  let (stoppedZh, _) = HarnessReducer.reduce(stoppingState, .exited(code: 0, signal: nil), language: .zhHans)
  checks.equal(stoppedZh.snapshot.lastRun, "刚刚", "a clean stop in Chinese")
  checks.check(!stoppedState.intentionalStop, "the stop flag clears")

  let (killState, killCommands) = HarnessReducer.reduce(
    stoppingState,
    .killTimedOut,
    language: .en
  )
  checks.equal(killState.snapshot.phase, .stopping, "a kill wait stays stopping")
  checks.equal(killCommands, [.kill], "a kill wait escalates to SIGKILL")

  let (cancelState, cancelCommands) = HarnessReducer.reduce(
    state,
    .cancel,
    language: .en
  )
  checks.equal(cancelState.snapshot.phase, .stopped, "cancel returns to stopped")
  checks.check(cancelCommands.contains(.terminate), "cancel terminates the child")

  let (idleStop, idleCommands) = HarnessReducer.reduce(
    HarnessState(),
    .stopRequested,
    language: .en
  )
  checks.equal(idleStop.snapshot.phase, .stopped, "stop on a stopped server does nothing")
  checks.equal(idleCommands, [], "stop on a stopped server runs nothing")

  let lateStart = HarnessReducer.reduce(readyState, .start(port: 3080, profile: "web"), language: .en)
  checks.equal(lateStart.1, [], "starting a listening server is ignored")
  checks.equal(lateStart.0.snapshot.phase, .listening, "the listening server keeps running")

  let (resetState, resetCommands) = HarnessReducer.reduce(
    crashState,
    .reset,
    language: .en
  )
  checks.equal(resetState.snapshot.phase, .stopped, "reset returns to stopped")
  checks.equal(resetState.snapshot.failure, nil, "reset clears the failure")
  checks.check(resetCommands.contains(.stopUptime), "reset stops the clock")

  let (missingState, _) = HarnessReducer.reduce(
    HarnessState(),
    .detectionFailed(searched: ["/x/dsh"]),
    language: .en
  )
  checks.equal(missingState.snapshot.phase, .unavailable, "a failed lookup is unavailable")
  checks.equal(missingState.searched, ["/x/dsh"], "the lookup keeps what it tried")
  let (foundState, _) = HarnessReducer.reduce(missingState, .detected(path: "/x/dsh"), language: .en)
  checks.equal(foundState.snapshot.phase, .stopped, "a later detection recovers")

  // MARK: Reducer — a stop that did not take

  let externalListening = HarnessReducer.reduce(state, .portChecked(.dsh, port: 3099), language: .en).0
  let externalStopping = HarnessReducer.reduce(externalListening, .stopRequested, language: .en).0
  let (stopFailedState, stopFailedCommands) = HarnessReducer.reduce(
    externalStopping,
    .stopFailed(port: 3099, detail: "pid 42 is not a dsh this app may stop"),
    language: .en
  )
  checks.equal(stopFailedState.snapshot.phase, .failed, "a failed external stop fails")
  checks.equal(stopFailedState.snapshot.failure?.port, 3099, "a failed stop names the port")
  checks.equal(
    stopFailedState.snapshot.failure?.detail,
    "pid 42 is not a dsh this app may stop",
    "a failed stop keeps its reason"
  )
  checks.check(!stopFailedState.intentionalStop, "a failed stop clears the intent flag")
  checks.equal(stopFailedCommands, [.stopUptime, .disarmReadyTimeout], "a failed stop stops the clock")

  // A startup-failure line only means something to a start that is still running.
  let (withDetail, _) = HarnessReducer.reduce(
    state,
    .launch(.startupFailed(detail: "boom")),
    language: .en
  )
  checks.equal(withDetail.pendingDetail, "boom", "a startup failure is remembered while starting")
  let (lateDetail, lateDetailCommands) = HarnessReducer.reduce(
    readyState,
    .launch(.startupFailed(detail: "late")),
    language: .en
  )
  checks.equal(lateDetail, readyState, "a late startup-failure line is ignored")
  checks.equal(lateDetailCommands, [], "a late startup-failure line runs nothing")
  let (clearedDetail, _) = HarnessReducer.reduce(
    withDetail,
    .launch(.ready(report)),
    language: .en,
    now: t0
  )
  checks.equal(clearedDetail.pendingDetail, nil, "a ready launch clears the remembered failure")

  // MARK: Reducer — external observation

  // A server started in a terminal must appear without the user pressing Start.
  let idle = HarnessState()
  let (seenExternal, seenCommands) = HarnessReducer.reduce(
    idle,
    .observedExternal(port: 3080),
    language: .en
  )
  checks.equal(seenExternal.snapshot.phase, .listening, "an observed dsh listens")
  checks.equal(seenExternal.snapshot.owner, .external, "an observed dsh is external")
  checks.check(!seenExternal.snapshot.hasLaunchURL, "an observed dsh has no token")
  checks.equal(seenCommands, [.stopUptime], "observing stops the idle clock")

  let (seenAgain, seenAgainCommands) = HarnessReducer.reduce(
    seenExternal,
    .observedExternal(port: 3080),
    language: .en
  )
  checks.equal(seenAgain, seenExternal, "observing twice changes nothing")
  checks.equal(seenAgainCommands, [], "observing twice runs nothing")

  let (goneState, goneCommands) = HarnessReducer.reduce(
    seenExternal,
    .observedFree(port: 3080),
    language: .en
  )
  checks.equal(goneState.snapshot.phase, .stopped, "a vanished external dsh is stopped")
  checks.check(!goneState.snapshot.hasLaunchURL, "a vanished external dsh leaves no URL")
  checks.equal(goneCommands, [.stopUptime], "a vanished external dsh stops the clock")

  let (wrongPort, wrongCommands) = HarnessReducer.reduce(
    seenExternal,
    .observedFree(port: 3099),
    language: .en
  )
  checks.equal(wrongPort, seenExternal, "a report for another port is ignored")
  checks.equal(wrongCommands, [], "a report for another port runs nothing")

  let owned = HarnessReducer.reduce(
    HarnessState(),
    .start(port: 3099, profile: "web"),
    language: .en
  ).0
  let (ownedExternal, _) = HarnessReducer.reduce(owned, .observedExternal(port: 3099), language: .en)
  checks.equal(ownedExternal.snapshot.phase, .starting, "observing does not hijack a start in progress")

  // MARK: Reducer — preferences

  let (movedPort, movedCommands) = HarnessReducer.reduce(
    HarnessState(),
    .preferencesChanged(port: 3099, profile: "tui"),
    language: .en
  )
  checks.equal(movedPort.snapshot.port, 3099, "a preferences change follows the new port")
  checks.equal(movedPort.snapshot.profile, "tui", "a preferences change follows the new profile")
  checks.equal(movedCommands, [], "a preferences change runs nothing")
  let (busyPort, _) = HarnessReducer.reduce(
    seenExternal,
    .preferencesChanged(port: 3099, profile: "web"),
    language: .en
  )
  checks.equal(busyPort, seenExternal, "a preferences change cannot move a listening server")

  // MARK: Child process guard

  do {
    _ = try ChildProcess(executable: "/nonexistent/dsh", arguments: [], environment: [:])
    checks.check(false, "a missing executable is rejected")
  } catch {
    checks.check(true, "a missing executable is rejected")
  }
  checks.check(
    ExternalInstance.canStop(ExternalInstance.Info(pid: 42, command: "node /x/dsh/lib/bin.js web", group: 42)),
    "a dsh command line may be stopped"
  )
  checks.check(
    !ExternalInstance.canStop(ExternalInstance.Info(pid: 42, command: "/usr/bin/python3 -m http.server", group: 42)),
    "an unrelated server may not"
  )
  checks.check(
    !ExternalInstance.canStop(ExternalInstance.Info(pid: 42, command: "node dsh", group: getpgrp())),
    "our own process group may not"
  )

  // Releasing a ChildProcess is what stops it — that is the whole point of owning
  // one. A handoff ("quit, keep it running") is the one case where the process must
  // survive that release, so `detach()` has to be honoured by `deinit`; without it
  // ARC kills the server a moment after the app promises to keep it.
  var detachedPID: pid_t = 0
  if let sleeper = try? ChildProcess(executable: "/bin/sleep", arguments: ["sleep", "60"], environment: [:]) {
    detachedPID = sleeper.pid
    sleeper.detach()
    checks.check(sleeper.isAlive, "a detached child is alive before it is released")
    usleep(300_000)
    checks.check(sleeper.isAlive, "a detached child stays alive while still referenced")
  } else {
    checks.check(false, "a sleep process could be spawned for the detach check")
  }
  usleep(300_000)
  // `kill(pid, 0)` says yes for a zombie too, so liveness is asked the same way the
  // handoff verifier asks it: `ps` knows a running process from a reaped one.
  checks.check(
    ExternalInstance.isAlive(ExternalInstance.Info(pid: detachedPID, command: "sleep")),
    "a detached child survives being released"
  )
  _ = Darwin.kill(detachedPID, SIGKILL)

  var attachedPID: pid_t = 0
  if let sleeper = try? ChildProcess(executable: "/bin/sleep", arguments: ["sleep", "60"], environment: [:]) {
    attachedPID = sleeper.pid
  } else {
    checks.check(false, "a sleep process could be spawned for the release check")
  }
  usleep(300_000)
  checks.check(
    !ExternalInstance.isAlive(ExternalInstance.Info(pid: attachedPID, command: "sleep")),
    "an attached child is stopped when its owner is released"
  )
  _ = Darwin.kill(attachedPID, SIGKILL)

  // MARK: Copy — take over

  checks.equal(en.takeOver, "Take over", "en take over")
  checks.equal(zh.takeOver, "接管", "zh take over")
  checks.equal(en.takeOverLabel, "Take over", "take over label before confirming")
  checks.equal(
    en.withTakeOverConfirmation(true).takeOverLabel,
    "Take over?",
    "take over label while confirming"
  )
  checks.check(zh.takeOverNote.contains("中断"), "zh take-over note warns about interruption")
  checks.check(en.takeOverNote.contains("interrupted"), "en take-over note warns about interruption")
  checks.equal(
    en.secondaryLabel(HarnessSnapshot(phase: .listening, owner: .external)),
    "Stop",
    "the external stop stays a separate, textual action"
  )

  // MARK: Copy — settings

  checks.equal(en.processSection, "Process", "en process section")
  checks.equal(zh.processSection, "进程", "zh process section")
  checks.equal(en.portAuto, "Auto", "en auto port")
  checks.check(zh.portInvalid.contains("1–65535"), "zh port hint names the range")
  checks.equal(en.versionLabel(nil), "not found", "unknown version")
  checks.equal(en.versionLabel("0.2.1-rc.5"), "dsh 0.2.1-rc.5", "version label")
  checks.equal(en.binarySource(.nvm), "nvm", "source label")
  checks.equal(
    en.portLabel(BarPreferences(port: 0, profile: "web")),
    "Auto",
    "auto port label"
  )
  checks.equal(
    en.portLabel(BarPreferences(port: 3099, profile: "web")),
    "3099",
    "explicit port label"
  )

  // MARK: Baked glyphs

  // Layers animate baked bitmaps, not paths: a missing bitmap would leave the
  // menu bar blank while a state is changing.
  checks.check(
    StatusIcon.bitmap(for: .starting, owner: .dshBar, color: .black) != nil,
    "the spin arc bakes into a bitmap"
  )
  checks.check(
    StatusIcon.dotBitmap(color: .white) != nil,
    "the listening dot bakes into a bitmap"
  )
  checks.check(
    StatusIcon.listeningRingImage().isTemplate,
    "the listening ring is a template image"
  )

  // MARK: Menu bar glyphs

  checks.check(StatusIcon.frames(for: .starting, owner: .dshBar) != nil, "starting animates")
  checks.check(StatusIcon.frames(for: .stopping, owner: .dshBar) != nil, "stopping animates")
  for phase in [HarnessPhase.unavailable, .stopped, .listening, .failed] {
    checks.check(StatusIcon.frames(for: phase, owner: .dshBar) == nil, "\(phase) holds still")
  }
  checks.equal(
    StatusIcon.frames(for: .starting, owner: .dshBar)?.count,
    StatusIcon.frameCount,
    "rotation covers a full turn"
  )
  checks.equal(StatusIcon.arrivalPulse(for: .dshBar).count, 8, "arrival pulse frame count")
  checks.check(StatusIcon.arrivalPulse(for: .dshBar).allSatisfy(\.isTemplate), "pulse frames are template images")
  for phase in HarnessPhase.allCases {
    let image = StatusIcon.image(for: phase, owner: .dshBar)
    checks.check(image.isTemplate, "\(phase) glyph is a template image")
    checks.equal(image.size, NSSize(width: 18, height: 18), "\(phase) glyph size")
  }

  // MARK: - Folder access

  let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("dshbar-check-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  FileManager.default.createFile(
    atPath: scratch.appendingPathComponent("note.txt").path,
    contents: Data("x".utf8)
  )

  let readable = FolderAccessStore.probe(scratch)
  checks.equal(readable.state, FolderAccessState.granted, "a folder we own reads as granted")
  checks.equal(readable.entryCount, 1, "the probe counts the entries")

  let gone = FolderAccessStore.probe(scratch.appendingPathComponent("nope", isDirectory: true))
  checks.equal(gone.state, FolderAccessState.missing, "a path that does not exist is missing")

  let file = scratch.appendingPathComponent("note.txt")
  checks.equal(FolderAccessStore.probe(file).state, FolderAccessState.missing, "a file is not a folder")

  // The refusal path is the one that matters: TCC denies a read with
  // NSCocoaErrorDomain 257, and a chmod 000 folder reproduces the same errno.
  let locked = scratch.appendingPathComponent("locked", isDirectory: true)
  try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
  chmod(locked.path, 0o000)
  let denial = FolderAccessStore.probe(locked)
  checks.equal(denial.state, FolderAccessState.denied, "an unreadable folder is reported as denied")
  checks.check(denial.detail?.contains("257") == true, "the denial names the cocoa error")
  chmod(locked.path, 0o755)

  let home = FileManager.default.homeDirectoryForCurrentUser
  checks.equal(
    FolderAccessStore.shortPath(home.appendingPathComponent("Documents", isDirectory: true)),
    "~/Documents",
    "the home directory is abbreviated"
  )
  checks.equal(FolderAccessStore.shortPath(home), "~", "the home directory itself is ~")
  checks.equal(
    FolderAccessStore.shortPath(URL(fileURLWithPath: "/opt/data")),
    "/opt/data",
    "paths outside the home stay absolute"
  )

  // A throwaway defaults domain: the bookmark layer must survive a relaunch, which
  // is the whole point of storing it.
  let folderSuite = "dev.dsh.bar.check.\(UUID().uuidString)"
  if let domain = UserDefaults(suiteName: folderSuite) {
    let store = FolderAccessStore(defaults: domain, folder: scratch)
    checks.check(!store.hasBookmark, "nothing is remembered before the first grant")
    checks.equal(store.snapshot().state, FolderAccessState.granted, "an ungrated but readable folder still reads")
    // A read is what raises the system sheet, so the report must be able to say
    // "not asked" without touching the folder.
    checks.equal(
      store.snapshot(probe: false).state,
      FolderAccessState.notRequested,
      "an unprobed, unremembered folder reports not requested"
    )
    checks.check(!store.startAccessing(), "no bookmark means no scope to acquire")

    let granted = try? store.grant(scratch)
    checks.check(store.hasBookmark, "granting stores a bookmark")
    checks.equal(granted?.state, FolderAccessState.granted, "a granted folder reads back as granted")
    checks.equal(store.storedPath, scratch.path, "the granted path is remembered")
    checks.check(store.startAccessing(), "the bookmark resolves after a relaunch")
    checks.equal(
      store.snapshot(probe: false).state,
      FolderAccessState.granted,
      "a remembered grant is read even when the caller asks for no probe"
    )
    checks.equal(store.snapshot().displayPath, FolderAccessStore.shortPath(scratch), "the row shows the granted folder")

    store.revoke()
    checks.check(!store.hasBookmark, "revoking drops the bookmark")
    checks.equal(store.snapshot().state, FolderAccessState.granted, "revoking does not touch the folder itself")
    domain.removePersistentDomain(forName: folderSuite)
  } else {
    checks.check(false, "a throwaway defaults domain could not be created")
  }

  try? FileManager.default.removeItem(at: scratch)

  // MARK: Copy — folder access

  checks.equal(en.folderSection, "Folder access", "en folder section")
  checks.equal(zh.folderSection, "文件夹权限", "zh folder section")
  checks.equal(en.authorize, "Authorize…", "en authorize")
  checks.equal(zh.documentsFolder, "文稿文件夹", "zh documents label")
  checks.check(zh.folderNote.contains("书签"), "zh note explains the remembered grant")
  checks.check(en.folderDeniedNote.contains("System Settings"), "en denied note points at System Settings")
  checks.check(zh.grantMessage.contains("~/Documents/deepseek-harness"), "the prompt says why")

  let grantSnapshot = FolderAccessSnapshot(
    folder: URL(fileURLWithPath: "/tmp/Documents"),
    displayPath: "~/Documents",
    state: .granted,
    entryCount: 6,
    detail: nil,
    hasBookmark: true,
    scoped: true
  )
  checks.equal(en.folderState(grantSnapshot), "granted · 6 items", "en granted label counts entries")
  checks.equal(zh.folderState(grantSnapshot), "已授权 · 6 项", "zh granted label counts entries")
  checks.equal(
    en.folderState(
      FolderAccessSnapshot(
        folder: URL(fileURLWithPath: "/tmp/Documents"),
        displayPath: "~/Documents",
        state: .notRequested,
        entryCount: 0,
        detail: nil,
        hasBookmark: false,
        scoped: false
      )
    ),
    "not requested",
    "an unasked folder is not called denied"
  )
  checks.check(
    DocumentsAccess.defaultWorkspaceURL.path.hasSuffix("deepseek-harness/default-workspace"),
    "the default workspace dsh uses is named once"
  )

  // MARK: - Environment for a GUI launch

  // The bug this models: a Finder-launched app inherits almost nothing, so dsh's
  // `#!/usr/bin/env node` cannot find its interpreter unless dsh's own directory
  // leads the PATH.
  checks.equal(
    LoginShellEnvironment.prependDirectory("/nvm/v24/bin", toPath: "/usr/bin:/bin"),
    "/nvm/v24/bin:/usr/bin:/bin",
    "the dsh directory is prepended to PATH"
  )
  checks.equal(
    LoginShellEnvironment.prependDirectory("/nvm/v24/bin", toPath: "/usr/bin:/nvm/v24/bin"),
    "/nvm/v24/bin:/usr/bin",
    "an existing entry moves to the front instead of duplicating"
  )
  checks.equal(
    LoginShellEnvironment.prependDirectory("/nvm/v24/bin/", toPath: nil),
    "/nvm/v24/bin",
    "a trailing slash is trimmed and an empty PATH is acceptable"
  )
  checks.equal(
    LoginShellEnvironment.runnablePath(
      forExecutable: "/nvm/v24/bin/dsh",
      environment: ["PATH": "/usr/bin"]
    ),
    "/nvm/v24/bin:/usr/bin",
    "runnablePath leads with the executable's own directory"
  )

  let toolDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("dshbar-tools-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: toolDir, withIntermediateDirectories: true)
  let fakeNode = toolDir.appendingPathComponent("node")
  FileManager.default.createFile(atPath: fakeNode.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
  try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeNode.path)
  checks.equal(
    LoginShellEnvironment.nodePath(onPath: "/usr/bin:\(toolDir.path)"),
    fakeNode.path,
    "node is found through PATH"
  )
  checks.check(!LoginShellEnvironment.hasNode(onPath: "/usr/bin:/bin"), "a bare PATH has no node")
  let oddDir = toolDir.appendingPathComponent("odd", isDirectory: true)
  try? FileManager.default.createDirectory(at: oddDir, withIntermediateDirectories: true)
  FileManager.default.createFile(atPath: oddDir.appendingPathComponent("node").path, contents: Data())
  checks.check(
    !LoginShellEnvironment.hasNode(onPath: oddDir.path),
    "a non-executable named node does not count"
  )

  let envNodeScript = toolDir.appendingPathComponent("dsh")
  FileManager.default.createFile(
    atPath: envNodeScript.path,
    contents: Data("#!/usr/bin/env node\nconsole.log(1)\n".utf8)
  )
  checks.check(DshLocator.isEnvNodeScript(at: envNodeScript.path), "an env-node shebang is recognised")

  let shellScript = toolDir.appendingPathComponent("sh-dsh")
  FileManager.default.createFile(
    atPath: shellScript.path,
    contents: Data("#!/bin/sh\nexit 0\n".utf8)
  )
  checks.check(!DshLocator.isEnvNodeScript(at: shellScript.path), "a shell script needs no node")

  let plainFile = toolDir.appendingPathComponent("plain")
  FileManager.default.createFile(atPath: plainFile.path, contents: Data("console.log(1)\n".utf8))
  checks.check(!DshLocator.isEnvNodeScript(at: plainFile.path), "a file without a shebang is not a node script")
  checks.check(
    !DshLocator.isEnvNodeScript(at: toolDir.appendingPathComponent("missing").path),
    "a missing file is not a node script"
  )

  // `zsh -lic` prints prompt escapes before the command output; the marker is what
  // keeps the first variable from being corrupted.
  let noisy = Data("\u{1B}]0;title\u{07}\(LoginShellEnvironment.marker)HOME=/Users/x\u{0}PATH=/usr/bin\u{0}".utf8)
  let sliced = LoginShellEnvironment.parse(LoginShellEnvironment.slice(noisy))
  checks.equal(sliced["HOME"], "/Users/x", "prompt noise before the marker is dropped")
  checks.equal(sliced["PATH"], "/usr/bin", "the marker does not leak into the first key")
  checks.equal(
    LoginShellEnvironment.parse(LoginShellEnvironment.slice(Data("HOME=/y\u{0}".utf8)))["HOME"],
    "/y",
    "output without a marker is parsed as it is"
  )

  let nodeDiagnosis = zh.diagnosis(HarnessFailure(kind: .nodeMissing))
  checks.check(nodeDiagnosis.title.contains("node"), "zh node diagnosis names node")
  checks.check(nodeDiagnosis.body.contains(".zshrc"), "zh node diagnosis points at ~/.zshrc")
  checks.check(
    en.diagnosis(HarnessFailure(kind: .nodeMissing)).body.contains("PATH"),
    "en node diagnosis explains the PATH"
  )

  try? FileManager.default.removeItem(at: toolDir)

  // MARK: - M3 · Launch paths (round 3, W1)

  checks.equal(BarPreferences.normalizeWorkspacePath("   "), nil, "a blank workspace stays unset")
  let homeExpanded = BarPreferences.normalizeWorkspacePath("~/Code/lab")
  checks.check(
    homeExpanded?.hasPrefix("/") == true && homeExpanded?.hasSuffix("/Code/lab") == true,
    "a workspace path expands ~"
  )
  checks.equal(
    BarPreferences.normalizeWorkspacePath("/tmp//a/../b"),
    "/tmp/b",
    "a workspace path collapses // and .."
  )
  checks.equal(
    BarPreferences.normalizeWorkspacePath("dsh-lab"),
    "dsh-lab",
    "a relative workspace is kept for the error message"
  )
  checks.equal(BarPreferences.normalizeDshHome("  "), nil, "a blank DSH_HOME is unset")

  let pathScratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("dshbar-paths-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: pathScratch, withIntermediateDirectories: true)
  let pathFile = pathScratch.appendingPathComponent("file.txt")
  FileManager.default.createFile(atPath: pathFile.path, contents: Data("x".utf8))

  let unsetPaths = LaunchTarget.resolve(BarPreferences())
  checks.equal(unsetPaths.workingDirectory, nil, "an unset workspace sends no chdir")
  checks.equal(unsetPaths.workspaceOrigin, .dshDefault, "an unset workspace is dsh's own")
  checks.equal(unsetPaths.dshHome, nil, "follow-shell inherits DSH_HOME")
  checks.equal(unsetPaths.dshHomeOrigin, .shell, "follow-shell says where it came from")
  checks.check(unsetPaths.isRunnable, "the defaults are always runnable")
  checks.check(unsetPaths.environmentOverlay.isEmpty, "the defaults overlay nothing")

  let goodPaths = LaunchTarget.resolve(
    BarPreferences(workspacePath: pathScratch.path, dshHomeMode: .override, dshHome: "~/dsh-state")
  )
  checks.equal(goodPaths.workingDirectory, pathScratch.path, "an existing workspace becomes the cwd")
  checks.equal(goodPaths.workspaceOrigin, .preference, "a configured workspace says so")
  checks.equal(
    goodPaths.environmentOverlay["DSH_HOME"],
    BarPreferences.collapse("~/dsh-state"),
    "an override reaches the child as DSH_HOME"
  )
  checks.check(goodPaths.isRunnable, "two usable paths are runnable")

  let missingPaths = LaunchTarget.resolve(BarPreferences(workspacePath: pathScratch.appendingPathComponent("nope").path))
  checks.equal(
    missingPaths.workspaceProblem,
    .missing(path: pathScratch.appendingPathComponent("nope").path),
    "a missing workspace is named"
  )
  checks.check(!missingPaths.isRunnable, "a missing workspace blocks the launch")

  let filePaths = LaunchTarget.resolve(BarPreferences(workspacePath: pathFile.path))
  checks.equal(
    filePaths.workspaceProblem,
    .notDirectory(path: pathFile.path),
    "a file is not a working directory"
  )

  let relativePaths = LaunchTarget.resolve(BarPreferences(workspacePath: "dsh-lab"))
  checks.equal(relativePaths.workspaceProblem, .relative(path: "dsh-lab"), "a relative path is rejected")
  checks.check(
    relativePaths.workspaceProblem?.isRelative == true,
    "a relative path is reported as such"
  )

  let defaultHome = LaunchTarget.resolve(BarPreferences(dshHomeMode: .override))
  checks.equal(defaultHome.dshHome, BarPreferences.collapse(BarPreferences.defaultDshHome), "a blank override means ~/.dsh")
  checks.equal(defaultHome.dshHomeOrigin, .ownDefault, "a blank override is the app's default")

  let badHome = LaunchTarget.resolve(
    BarPreferences(dshHomeMode: .override, dshHome: pathFile.path)
  )
  checks.equal(
    badHome.dshHomeProblem,
    .notDirectory(path: pathFile.path),
    "DSH_HOME pointing at a file is refused"
  )
  checks.equal(LaunchTarget.shortPath("/Users/x/Code", home: "/Users/x"), "~/Code", "a long path is abbreviated for the row")
  checks.equal(LaunchTarget.shortPath("/opt/data", home: "/Users/x"), "/opt/data", "a path outside home stays absolute")

  let richSuite = "dev.dsh.bar.check.rich.\(UUID().uuidString)"
  if let domain = UserDefaults(suiteName: richSuite) {
    let rich = BarPreferences(
      binaryPath: "/x/dsh",
      port: 3099,
      profile: "tui",
      workspacePath: "~/Code/lab",
      dshHomeMode: .override,
      dshHome: "~/state",
      quitBehavior: .keepRunning,
      hotKey: .controlOptionD
    )
    rich.save(to: domain)
    checks.equal(BarPreferences.load(from: domain), rich, "M3 preferences round-trip")
    checks.equal(BarPreferences.load(from: domain).workspacePath, BarPreferences.collapse("~/Code/lab"), "the workspace survives a relaunch")
    checks.equal(BarPreferences.load(from: domain).dshHomeMode, .override, "the DSH_HOME mode survives")
    checks.equal(BarPreferences.load(from: domain).quitBehavior, .keepRunning, "the quit behaviour survives")
    checks.equal(BarPreferences.load(from: domain).hotKey, .controlOptionD, "the shortcut survives")

    // A 0.3.0 defaults domain has none of the M3 keys: the upgrade must change nothing.
    let legacy = "dev.dsh.bar.check.legacy.\(UUID().uuidString)"
    if let old = UserDefaults(suiteName: legacy) {
      old.set(3080, forKey: BarPreferences.Key.port)
      old.set("web", forKey: BarPreferences.Key.profile)
      let loaded = BarPreferences.load(from: old)
      checks.equal(loaded.workspacePath, nil, "an old domain has no workspace")
      checks.equal(loaded.dshHomeMode, .followShell, "an old domain follows the shell")
      checks.equal(loaded.quitBehavior, .stopManaged, "an old domain stops on quit")
      checks.equal(loaded.hotKey, .optionCommandD, "an old domain gets the default shortcut")
      old.removePersistentDomain(forName: legacy)
    }
    domain.removePersistentDomain(forName: richSuite)
  } else {
    checks.check(false, "a throwaway defaults domain could not be created")
  }

  let workspaceDiagnosis = zh.diagnosis(HarnessFailure(kind: .workspaceMissing(path: "/tmp/gone")))
  checks.check(workspaceDiagnosis.title.contains("工作目录"), "zh workspace diagnosis names the directory")
  checks.check(workspaceDiagnosis.body.contains("/tmp/gone"), "zh workspace diagnosis quotes the path")
  let homeDiagnosis = en.diagnosis(HarnessFailure(kind: .dshHomeMissing(path: "/tmp/file")))
  checks.check(homeDiagnosis.title.contains("DSH_HOME"), "en DSH_HOME diagnosis names the variable")
  checks.check(homeDiagnosis.body.contains("/tmp/file"), "en DSH_HOME diagnosis quotes the path")

  checks.equal(HarnessFailure(kind: .portInUse(port: 1)).recovery, .freePort, "a port failure offers a free port")
  checks.equal(HarnessFailure(kind: .workspaceMissing(path: "/x")).recovery, .defaultPaths, "a path failure offers the defaults")
  checks.equal(HarnessFailure(kind: .nodeMissing).recovery, nil, "a node failure offers no invented repair")
  checks.equal(
    en.secondaryLabel(HarnessSnapshot(phase: .failed, failure: HarnessFailure(kind: .workspaceMissing(path: "/x")))),
    "Use defaults",
    "the path failure's second button says what it does"
  )
  checks.equal(
    zh.secondaryLabel(HarnessSnapshot(phase: .failed, failure: HarnessFailure(kind: .dshHomeMissing(path: "/x")))),
    "改回默认",
    "the Chinese second button says what it does"
  )
  checks.equal(HarnessFailure(kind: .workspaceMissing(path: "/x")).path, "/x", "a failure can name its path")

  // Only the port may change when a start adopts a real port (an OS-assigned one, or
  // a take-over on another port). Rebuilding the struct instead silently reset the
  // five fields 0.4.0 added, and saved that to disk.
  let richPrefs = BarPreferences(
    binaryPath: "/x/dsh",
    port: 3080,
    profile: "tui",
    workspacePath: "~/Code/lab",
    dshHomeMode: .override,
    dshHome: "~/state",
    quitBehavior: .keepRunning,
    hotKey: .controlOptionD
  )
  let renumbered = richPrefs.replacing(port: 3099)
  checks.equal(renumbered.port, 3099, "replacing the port takes the new port")
  checks.equal(renumbered.profile, "tui", "replacing the port keeps the profile")
  checks.equal(renumbered.binaryPath, "/x/dsh", "replacing the port keeps the binary")
  checks.equal(renumbered.workspacePath, richPrefs.workspacePath, "replacing the port keeps the workspace")
  checks.equal(renumbered.dshHomeMode, .override, "replacing the port keeps the DSH_HOME mode")
  checks.equal(renumbered.dshHome, richPrefs.dshHome, "replacing the port keeps the DSH_HOME path")
  checks.equal(renumbered.quitBehavior, .keepRunning, "replacing the port keeps the quit behaviour")
  checks.equal(renumbered.hotKey, .controlOptionD, "replacing the port keeps the shortcut")
  checks.equal(BarPreferences(port: 3080).replacing(port: 0).port, 0, "replacing accepts the auto port")
  checks.equal(BarPreferences(port: 3080).replacing(port: 70_000).port, 3080, "replacing normalises an impossible port")

  checks.equal(en.reading, "reading…", "en reading placeholder")
  checks.equal(zh.reading, "读取中…", "zh reading placeholder")
  checks.equal(zh.notAFolder("/tmp/f"), "不是文件夹：/tmp/f", "zh not-a-folder names the path")
  checks.check(en.notAFolder("/tmp/f").contains("/tmp/f"), "en not-a-folder names the path")
  checks.check(zh.noSuchFolder("/tmp/gone").contains("/tmp/gone"), "zh missing folder names the path")
  checks.check(en.detectionMissing.contains("nvm"), "en detection note names the places searched")
  checks.check(zh.detectionMissing.contains("Homebrew"), "zh detection note names the places searched")

  let (workspaceFailedState, _) = HarnessReducer.reduce(
    state,
    .spawnFailed(HarnessFailure(kind: .workspaceMissing(path: "/tmp/gone"))),
    language: .en
  )
  checks.equal(workspaceFailedState.snapshot.failure?.kind, .workspaceMissing(path: "/tmp/gone"), "a refused spawn keeps the path")
  checks.equal(workspaceFailedState.snapshot.phase, HarnessPhase.failed, "a refused spawn fails the start")

  try? FileManager.default.removeItem(at: pathScratch)

  // MARK: - M3 · Environment report (W2)

  checks.equal(EnvironmentReport.head(of: "/a:/b:/c:/d"), "/a:/b:/c", "the PATH head keeps three entries")
  checks.equal(EnvironmentReport.head(of: "/a:/b"), "/a:/b", "a short PATH is not padded")
  checks.equal(EnvironmentReport.head(of: ""), "", "an empty PATH has an empty head")
  checks.equal(EnvironmentReport.head(of: "::/a::/b::/c"), "/a:/b:/c", "empty PATH entries are skipped")

  let interactiveReport = EnvironmentReport.make(
    values: ["PATH": "/nvm/bin:/usr/bin", "HOME": "/h", "DSH_HOME": "/h/.dsh"],
    source: .interactiveShell,
    durationMs: 412,
    nodeVersion: "v24.22.2",
    nodePath: "/nvm/bin/node"
  )
  checks.equal(interactiveReport.variableCount, 3, "the report counts the variables")
  checks.equal(interactiveReport.pathHead, "/nvm/bin:/usr/bin", "the report keeps the PATH head")
  checks.check(interactiveReport.hasNode, "the report knows it has node")
  checks.check(!interactiveReport.isDegraded, "an interactive shell with node is healthy")
  checks.equal(interactiveReport.failureNote, nil, "a healthy report has no note")
  checks.equal(interactiveReport.durationMs, 412, "the report keeps the cost")

  let processReport = EnvironmentReport.make(
    values: ["PATH": "/usr/bin:/bin"],
    source: .process,
    durationMs: 3
  )
  checks.check(processReport.isDegraded, "the process environment is degraded")
  checks.check(processReport.failureNote?.contains("no shell") == true, "a missing shell is named")
  checks.check(processReport.failureNote?.contains("no node") == true, "a missing node is named too")
  checks.equal(processReport.nodePath, nil, "a PATH without node reports no node")

  let loginReport = EnvironmentReport.make(values: ["PATH": "/x"], source: .loginShell, durationMs: 20, nodePath: "/x/node")
  checks.check(loginReport.failureNote?.contains(".zshrc") == true, "the login-shell report names the missing rc exports")

  checks.equal(en.environmentSource(.interactiveShell), "interactive login shell", "en interactive source label")
  checks.equal(zh.environmentSource(.loginShell), "登录 shell（未读 rc）", "zh login source label")
  checks.equal(en.environmentSource(.process), "process environment", "en process source label")
  checks.equal(en.environmentTiming(interactiveReport), "412 ms", "the timing is milliseconds")
  checks.equal(en.environmentNodeMissing, "no node", "the node row has a missing state")
  checks.check(zh.environmentFallbackNote.contains("~/.zshrc"), "zh fallback note points at ~/.zshrc")
  checks.check(zh.environmentLoginShellNote.contains("node"), "zh login-shell note explains the node risk")
  checks.equal(en.reread, "Read again", "en reread button")

  // MARK: - M3 · Handoff (W3)

  let handoffSuite = "dev.dsh.bar.check.handoff.\(UUID().uuidString)"
  if let domain = UserDefaults(suiteName: handoffSuite) {
    checks.equal(HandoffStore.load(from: domain), nil, "nothing is remembered before a handoff")
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let record = HandoffRecord(pid: 4326, port: 3099, startedAt: startedAt, launchURL: "http://127.0.0.1:3099/?token=x")
    HandoffStore.save(record, to: domain)
    checks.equal(
      HandoffStore.load(from: domain),
      HandoffRecord(pid: 4326, port: 3099, startedAt: startedAt, launchURL: "http://127.0.0.1:3099/?token=…"),
      "a handoff record survives a relaunch, without its token"
    )
    checks.equal(HandoffStore.load(from: domain)?.pid, 4326, "the record keeps the pid")
    checks.equal(HandoffStore.load(from: domain)?.port, 3099, "the record keeps the port")

    checks.equal(
      HandoffVerifier.verify(nil, inspection: HandoffInspection(pidAlive: true, command: "node dsh", portServesDsh: true)),
      .noRecord,
      "no record means no verdict"
    )
    checks.equal(
      HandoffVerifier.verify(record, inspection: HandoffInspection(pidAlive: false, command: nil, portServesDsh: false)),
      .pidGone,
      "a dead pid drops the claim"
    )
    checks.equal(
      HandoffVerifier.verify(
        record,
        inspection: HandoffInspection(pidAlive: true, command: "/usr/bin/python3 -m http.server", portServesDsh: true)
      ),
      .notDsh,
      "a pid that is not a dsh is refused"
    )
    checks.equal(
      HandoffVerifier.verify(
        record,
        inspection: HandoffInspection(pidAlive: true, command: "node /Users/x/dsh/lib/bin.js web", portServesDsh: false)
      ),
      .portMoved,
      "a dsh on another port is not this handoff"
    )
    checks.equal(
      HandoffVerifier.verify(
        record,
        inspection: HandoffInspection(pidAlive: true, command: "node /Users/x/dsh/lib/bin.js web", group: 4326, portServesDsh: true)
      ),
      .valid,
      "a live dsh on the recorded port is the handoff"
    )
    checks.check(HandoffVerdict.valid.isUsable, "a valid verdict is usable")
    checks.check(!HandoffVerdict.pidGone.isUsable, "a dead pid is not usable")

    HandoffStore.clear(from: domain)
    checks.equal(HandoffStore.load(from: domain), nil, "clearing forgets the handoff")
    domain.removePersistentDomain(forName: handoffSuite)
  } else {
    checks.check(false, "a throwaway defaults domain could not be created")
  }

  let (handoffState, handoffCommands) = HarnessReducer.reduce(
    HarnessState(),
    .observedHandoff(port: 3099),
    language: .en
  )
  checks.equal(handoffState.snapshot.phase, .listening, "a handoff server listens")
  checks.equal(handoffState.snapshot.owner, .external, "a handoff server is external")
  checks.check(handoffState.snapshot.handoff, "a handoff server is marked as ours-once")
  checks.check(!handoffState.snapshot.hasLaunchURL, "a handoff server has no token")
  checks.equal(handoffCommands, [.stopUptime], "observing a handoff stops the idle clock")

  let (plainExternal, _) = HarnessReducer.reduce(HarnessState(), .observedExternal(port: 3099), language: .en)
  checks.check(!plainExternal.snapshot.handoff, "a terminal server carries no handoff mark")
  checks.equal(
    en.readoutSide(handoffState.snapshot),
    "started by dsh bar",
    "the readout names the handoff"
  )
  checks.equal(en.readoutSide(plainExternal.snapshot), "started in a terminal", "a terminal server keeps its own note")
  checks.check(zh.handoffNote.contains("接管"), "zh handoff note offers a way out")
  checks.check(en.handoffNote.contains("token"), "en handoff note explains the missing token")

  var staleHandoff = HarnessState()
  staleHandoff.snapshot.handoff = true
  let (afterStart, _) = HarnessReducer.reduce(staleHandoff, .start(port: 3099, profile: "web"), language: .en)
  checks.check(!afterStart.snapshot.handoff, "starting a new server clears the mark")
  let (afterGone, _) = HarnessReducer.reduce(handoffState, .observedFree(port: 3099), language: .en)
  checks.check(!afterGone.snapshot.handoff, "a vanished handoff clears the mark")

  checks.equal(QuitBehavior.label(.stopManaged, language: .en), "Stop the server", "en stop-on-quit label")
  checks.equal(QuitBehavior.label(.keepRunning, language: .zhHans), "保持运行", "zh keep-running label")
  checks.equal(QuitBehavior.label(.ask, language: .en), "Ask every time", "en ask-on-quit label")
  checks.equal(QuitBehavior.allCases.count, 3, "three quit behaviours")

  // MARK: - M3 · Single instance & shortcut (W4)

  checks.equal(
    SingleInstance.decision(running: [], myPID: 10, myBundleIdentifier: "dev.dsh.bar"),
    .runMyself,
    "the first launch runs"
  )
  checks.equal(
    SingleInstance.decision(
      running: [
        SingleInstance.Resident(pid: 10, bundleIdentifier: "dev.dsh.bar"),
        SingleInstance.Resident(pid: 11, bundleIdentifier: "dev.dsh.bar"),
      ],
      myPID: 11,
      myBundleIdentifier: "dev.dsh.bar"
    ),
    .yield(to: 10),
    "a second launch defers to the first"
  )
  checks.equal(
    SingleInstance.decision(
      running: [SingleInstance.Resident(pid: 9, bundleIdentifier: "com.other.app")],
      myPID: 10,
      myBundleIdentifier: "dev.dsh.bar"
    ),
    .runMyself,
    "another app with a different identifier is not a copy"
  )
  checks.equal(
    SingleInstance.decision(
      running: [SingleInstance.Resident(pid: 9, bundleIdentifier: "dev.dsh.bar")],
      myPID: 10,
      myBundleIdentifier: nil
    ),
    .runMyself,
    "an unbundled build always runs"
  )
  checks.equal(
    SingleInstance.decision(
      running: [
        SingleInstance.Resident(pid: 12, bundleIdentifier: "dev.dsh.bar"),
        SingleInstance.Resident(pid: 11, bundleIdentifier: "dev.dsh.bar"),
      ],
      myPID: 10,
      myBundleIdentifier: "dev.dsh.bar"
    ),
    .yield(to: 11),
    "the oldest copy wins"
  )

  checks.equal(HotKeyChoice.default, .optionCommandD, "the default shortcut")
  checks.equal(HotKeyChoice.keyCodeD, 2, "D is virtual key 2")
  checks.equal(HotKeyChoice.optionCommandD.keyCode, 2, "option-command uses D")
  checks.equal(HotKeyChoice.optionCommandD.modifiers, 2304, "option-command is cmdKey|optionKey")
  checks.equal(HotKeyChoice.controlOptionD.modifiers, 6144, "control-option is controlKey|optionKey")
  checks.equal(HotKeyChoice.off.keyCode, nil, "off has no key")
  checks.equal(HotKeyChoice.off.modifiers, 0, "off has no modifiers")
  checks.check(!HotKeyChoice.off.isEnabled, "off is disabled")
  checks.check(HotKeyChoice.controlOptionD.isEnabled, "a chord is enabled")
  checks.equal(HotKeyChoice.optionCommandD.label, "⌥⌘D", "the option-command label")
  checks.equal(HotKeyChoice.controlOptionD.label, "⌃⌥D", "the control-option label")
  checks.equal(HotKeyChoice.off.label(language: .zhHans), "关闭", "zh off label")
  checks.equal(HotKeyChoice.controlOptionD.label(language: .en), "⌃⌥D", "the label ignores language while on")
  checks.check(HotKeyStatus.active.isActive, "an active chip is active")
  checks.check(!HotKeyStatus.taken.isActive, "a taken chord is not active")
  checks.check(zh.shortcutTaken.contains("占用"), "zh taken note says the chord is taken")

  // MARK: - M3 · Launch at login (W5)

  checks.equal(
    LaunchAtLogin.map(raw: 1, bundleIdentifier: "dev.dsh.bar", isSignedStably: true, reasonWhenUnavailable: nil),
    LoginItemStatus.enabled,
    "a registered login item is on"
  )
  checks.equal(
    LaunchAtLogin.map(raw: 2, bundleIdentifier: "dev.dsh.bar", isSignedStably: true, reasonWhenUnavailable: nil),
    LoginItemStatus.requiresApproval,
    "a pending login item asks for approval"
  )
  checks.equal(
    LaunchAtLogin.map(raw: 0, bundleIdentifier: "dev.dsh.bar", isSignedStably: true, reasonWhenUnavailable: nil),
    LoginItemStatus.notRegistered,
    "an unregistered login item is off"
  )
  checks.equal(
    LaunchAtLogin.map(raw: 3, bundleIdentifier: "dev.dsh.bar", isSignedStably: true, reasonWhenUnavailable: nil),
    LoginItemStatus.notRegistered,
    "a not-found login item is off"
  )
  if case .unavailable = LaunchAtLogin.map(raw: 1, bundleIdentifier: "dev.dsh.bar", isSignedStably: false, reasonWhenUnavailable: nil) {
    checks.check(true, "an ad-hoc signature cannot hold a login item")
  } else {
    checks.check(false, "an ad-hoc signature cannot hold a login item")
  }
  if case .unavailable = LaunchAtLogin.map(raw: 1, bundleIdentifier: nil, isSignedStably: true, reasonWhenUnavailable: "needs a bundle") {
    checks.check(true, "an unbundled build cannot register a login item")
  } else {
    checks.check(false, "an unbundled build cannot register a login item")
  }
  checks.check(LoginItemStatus.enabled.isOn, "enabled is on")
  checks.check(!LoginItemStatus.notRegistered.isOn, "unregistered is not on")
  checks.check(LoginItemStatus.requiresApproval.isOffered, "a pending item is still offered")
  checks.check(!LoginItemStatus.unavailable(reason: "x").isOffered, "an unavailable item is not offered")
  checks.check(LaunchAtLogin.deepLink.contains("LoginItems"), "the deep link opens Login Items")
  checks.equal(en.loginItemState(.enabled), "on", "en login item on")
  checks.equal(zh.loginItemState(.requiresApproval), "等待系统批准", "zh login item pending")
  checks.equal(en.loginItemState(.notRegistered), "off", "en login item off")
  checks.check(zh.loginItemUnsigned.contains("签名"), "zh unsigned note explains the signature")
  checks.equal(en.openLoginItems, "Open Login Items…", "en login items button")

  // MARK: - M4 · Keeping the machine awake (W1)

  // The policy is data so the settings row, the menu item, and the guard all read
  // one answer.
  checks.equal(SleepPolicy.default, .whileListening, "the default policy asserts while serving")
  checks.check(SleepPolicy.whileListening.isEnabled, "while-serving is enabled")
  checks.check(!SleepPolicy.off.isEnabled, "off asserts nothing")
  checks.equal(SleepPolicy.label(.off, language: .zhHans), "关闭", "zh off policy label")
  checks.equal(SleepPolicy.label(.whileListening, language: .zhHans), "服务运行时", "zh while-serving label")
  checks.equal(SleepPolicy.label(.off, language: .en), "Off", "en off policy label")
  checks.equal(SleepPolicy.label(.whileListening, language: .en), "While serving", "en while-serving label")
  checks.equal(SleepPolicy.forced(from: ["DSHBAR_SLEEP_POLICY": "off"]), .off, "the debug hook reads off")
  checks.equal(
    SleepPolicy.forced(from: ["DSHBAR_SLEEP_POLICY": "whileListening"]),
    .whileListening,
    "the debug hook reads while-serving"
  )
  checks.equal(SleepPolicy.forced(from: ["DSHBAR_SLEEP_POLICY": "bogus"]), nil, "an unknown hook value is ignored")
  checks.equal(SleepPolicy.forced(from: [:]), nil, "a missing hook leaves the preference in charge")

  // The command line: `-i` and `-w`, and nothing that would keep the display lit.
  checks.equal(Caffeinate.flags, ["-i"], "the only flag is -i")
  checks.equal(Caffeinate.executable, "/usr/bin/caffeinate", "the tool is the system one")
  let servingArgs = Caffeinate.arguments(for: .whileListening, watching: 4242) ?? []
  checks.equal(servingArgs, ["-i", "-w", "4242"], "the assertion names the watched pid")
  checks.check(servingArgs.contains("-i"), "the system-sleep assertion is requested")
  for flag in Caffeinate.forbiddenFlags {
    checks.check(!servingArgs.contains(flag), "the assertion never passes \(flag)")
  }
  checks.equal(Caffeinate.arguments(for: .off, watching: 4242), nil, "a disabled policy builds no command")
  checks.equal(Caffeinate.arguments(for: .whileListening, watching: 0), nil, "no pid means no command")
  checks.check(
    (Caffeinate.describe(for: .whileListening, watching: 4242) ?? "").hasSuffix("/usr/bin/caffeinate -i -w 4242"),
    "the logged command names the tool, the flag, and the pid"
  )
  checks.check(Caffeinate.isAvailable(), "caffeinate exists on this system")

  // `pmset -g assertions` as captured on this machine, caffeinate included. Parsing
  // it is what turns "the display may sleep" into something a test can read.
  let pmsetSample = [
    "2026-11-06 09:42:02 +0800 ",
    "Assertion status system-wide:",
    "   BackgroundTask                 0",
    "   PreventUserIdleDisplaySleep    0",
    "   PreventUserIdleSystemSleep     1",
    "Listed by owning process:",
    "   pid 262(powerd): [0x00022f6f00018c7a] 00:19:17 PreventUserIdleSystemSleep named: \"Powerd - Prevent sleep while display is on\"  ",
    "   pid 262(powerd): [0x0000604f00098e14] 48:40:28 UserIsActive named: \"com.apple.powermanagement.lidopen\"  ",
    "   pid 290(apsd): [0x000233f400018dc3] 00:00:00 NoIdleSleepAssertion named: \"com.apple.apsd-keepalive-push.apple.com-NonCellular\"  ",
    "   pid 57912(caffeinate): [0x000233f400018dc2] 00:00:00 PreventUserIdleSystemSleep named: \"caffeinate command-line tool\"  ",
    "\tDetails: caffeinate asserting on behalf of Process ID 57911",
    "\tCreated for PID: 57911. ",
    "\tLocalized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.",
    "Kernel Assertions: 0x104=USB,MAGICWAKE",
    "   id=542  level=255 0x100=MAGICWAKE creat=2026/11/3 00:00  mod=2026/11/6 08:52 description=en0 owner=IOSkywalkNetworkBSDClient",
  ].joined(separator: "\n")

  let assertions = SleepAssertion.parse(pmsetSample)
  checks.equal(assertions.count, 4, "every assertion line is parsed")
  checks.equal(SleepAssertion.parse("").count, 0, "an empty listing has no assertions")
  let caffeinateLines = SleepAssertion.caffeinateAssertions(in: pmsetSample)
  checks.equal(caffeinateLines.count, 1, "only the caffeinate assertion is the guard's")
  checks.equal(caffeinateLines.first?.pid, 57912, "the caffeinate pid is read")
  checks.equal(caffeinateLines.first?.watchedPID, 57911, "the watched pid comes from the continuation line")
  checks.equal(caffeinateLines.first?.kind, .idleSystem, "caffeinate holds the idle-system assertion")
  checks.equal(caffeinateLines.first?.name, "caffeinate command-line tool", "the assertion name is kept")
  checks.check(
    caffeinateLines.allSatisfy { $0.kind != .idleDisplay },
    "caffeinate never holds the idle-display assertion"
  )
  checks.equal(
    assertions.first(where: { $0.processName == "apsd" })?.kind,
    .other,
    "an unknown assertion kind parses as other"
  )
  checks.equal(
    assertions.first(where: { $0.kind == SleepAssertion.Kind.userActive })?.watchedPID,
    nil as Int?,
    "a plain user-active assertion has no watched pid"
  )
  checks.equal(SleepAssertion.Kind(raw: "PreventUserIdleDisplaySleep"), .idleDisplay, "the display kind maps")
  checks.equal(SleepAssertion.Kind(raw: "PreventSystemSleep"), .systemSleep, "the system kind maps")
  checks.equal(SleepAssertion.Kind(raw: "BackgroundTask"), .backgroundTask, "the background kind maps")

  // The decision table, without a single process.
  let asserting7 = SleepGuardStatus.asserting(pid: 7)
  checks.check(asserting7.isAsserting, "an asserting status is asserting")
  checks.equal(asserting7.assertingPID, 7, "an asserting status names its pid")
  checks.check(!SleepGuardStatus.idle.isAsserting, "idle is not asserting")
  checks.check(!SleepGuardStatus.failed(detail: "x").isAsserting, "a failed guard is not asserting")
  checks.check(!SleepGuardStatus.unavailable(reason: "x").isAsserting, "an unavailable guard is not asserting")

  func plan(
    _ policy: SleepPolicy,
    _ watched: pid_t?,
    _ status: SleepGuardStatus,
    last: pid_t? = nil,
    failed: Bool = false
  ) -> SleepGuardPlan {
    SleepGuardPlan.plan(
      policy: policy,
      watched: watched,
      status: status,
      lastAttempted: last,
      lastAttemptFailed: failed
    )
  }
  checks.equal(plan(.off, 7, asserting7), .release, "turning the policy off releases the assertion")
  checks.equal(plan(.off, nil, .idle), .noop, "off with nothing held does nothing")
  checks.equal(plan(.off, 7, .idle), .noop, "off never arms")
  checks.equal(plan(.whileListening, nil, asserting7), .release, "no server means release")
  checks.equal(plan(.whileListening, nil, .idle), .noop, "no server and nothing held does nothing")
  checks.equal(plan(.whileListening, 7, asserting7), .noop, "the same pid is left alone")
  checks.equal(plan(.whileListening, 8, asserting7), .arm(pid: 8), "a new dsh pid swaps the assertion")
  checks.equal(plan(.whileListening, 7, .idle), .arm(pid: 7), "a listening server arms the guard")
  checks.equal(
    plan(.whileListening, 7, .idle, last: 7, failed: true),
    .noop,
    "a dead pid is not retried"
  )
  checks.equal(
    plan(.whileListening, 7, .idle, last: 9, failed: true),
    .arm(pid: 7),
    "a different pid is still tried after a failure"
  )
  checks.equal(plan(.whileListening, 0, .idle), .noop, "pid 0 is never watched")
  checks.equal(plan(.whileListening, 7, .failed(detail: "x"), last: 7, failed: true), .noop, "a failed guard waits")

  // Which pid may be watched at all. The rule is the feature: only a server this
  // app spawned, and only while it is listening.
  checks.equal(
    SleepGuardTarget.watchedPID(phase: .listening, owner: .dshBar, child: 31),
    31,
    "a managed listening server is watched"
  )
  checks.equal(
    SleepGuardTarget.watchedPID(phase: .listening, owner: .external, child: 31),
    nil,
    "a terminal server is not"
  )
  checks.equal(
    SleepGuardTarget.watchedPID(phase: .starting, owner: .dshBar, child: 31),
    nil,
    "a starting server holds nothing yet"
  )
  checks.equal(
    SleepGuardTarget.watchedPID(phase: .stopping, owner: .dshBar, child: 31),
    nil,
    "a stopping server gives the assertion up"
  )
  checks.equal(
    SleepGuardTarget.watchedPID(phase: .failed, owner: .dshBar, child: 31),
    nil,
    "a failed launch asserts nothing"
  )
  checks.equal(
    SleepGuardTarget.watchedPID(phase: .listening, owner: .dshBar, child: nil),
    nil,
    "no child means nothing to watch"
  )

  // How an unexpected exit is read: with `-w` the normal ending is "the tool went
  // with its server", which must not read as a failure in Settings.
  checks.equal(
    SleepGuardExit.status(code: 0, watchedAlive: false, watched: 12),
    .idle,
    "a caffeinate that ends with its dsh goes back to idle"
  )
  if case .failed = SleepGuardExit.status(code: 1, watchedAlive: true, watched: 12) {
    checks.check(true, "a caffeinate that dies while the dsh lives is a failure")
  } else {
    checks.check(false, "a caffeinate that dies while the dsh lives is a failure")
  }
  checks.check(
    SleepGuardExit.logLine(code: 0, watchedAlive: false, watched: 12).contains("with the dsh process"),
    "the log says the assertion ended with the server"
  )
  checks.check(
    SleepGuardExit.logLine(code: 1, watchedAlive: true, watched: 12).contains("is alive"),
    "the log names the anomaly when the dsh outlives the assertion"
  )

  // Copy: every status has both languages, and the missing tool is translated
  // rather than printed in English at a Chinese reader.
  checks.equal(en.sleepField, "Keep awake", "en sleep field")
  checks.equal(zh.sleepField, "防止休眠", "zh sleep field")
  checks.equal(en.awakeBadge, "awake", "en footer badge")
  checks.equal(zh.awakeBadge, "防休眠", "zh footer badge")
  checks.check(en.sleepNote.contains("caffeinate -i"), "en note names the flag")
  checks.check(en.sleepNote.contains("lid"), "en note says closing the lid still sleeps")
  checks.check(zh.sleepNote.contains("合盖"), "zh note says closing the lid still sleeps")
  checks.equal(en.sleepState(.idle), "not asserting", "en idle state")
  checks.equal(zh.sleepState(.idle), "未防止", "zh idle state")
  checks.check(en.sleepState(.asserting(pid: 42)).contains("42"), "en asserting state names the pid")
  checks.check(zh.sleepState(.asserting(pid: 42)).contains("42"), "zh asserting state names the pid")
  checks.equal(en.sleepState(.asserting(pid: 0)), "awake", "the fixture build omits a fake pid")
  checks.check(
    en.sleepState(.unavailable(reason: Caffeinate.missingReason)).contains("caffeinate is missing"),
    "en missing-tool reason is translated"
  )
  checks.check(
    zh.sleepState(.unavailable(reason: Caffeinate.missingReason)).contains("找不到"),
    "zh missing-tool reason is translated"
  )
  checks.check(
    en.sleepState(.unavailable(reason: "/usr/bin/caffeinate: denied")).contains("denied"),
    "a system error is passed through"
  )
  checks.check(en.sleepState(.failed(detail: "code 1")).hasPrefix("exited"), "en failure state reads as an exit")
  checks.equal(zh.sleepToolMissing, "找不到 /usr/bin/caffeinate", "zh missing-tool sentence")

  // The preference, and the one deliberate break of the "an upgrade changes
  // nothing" rule: a 0.4.0 domain has no sleep key and gets the feature.
  let sleepSuite = "dev.dsh.bar.check.sleep.\(UUID().uuidString)"
  if let domain = UserDefaults(suiteName: sleepSuite) {
    checks.equal(
      BarPreferences.load(from: domain).sleepPolicy,
      .whileListening,
      "a fresh domain keeps the machine awake while serving"
    )
    var off = BarPreferences.load(from: domain)
    off.sleepPolicy = .off
    off.save(to: domain)
    checks.equal(BarPreferences.load(from: domain).sleepPolicy, .off, "turning it off survives a relaunch")
    checks.equal(
      BarPreferences.load(from: domain).replacing(port: 3099).sleepPolicy,
      .off,
      "changing the port keeps the policy"
    )
    checks.equal(
      BarPreferences.load(from: domain).replacing(port: 3099).port,
      3099,
      "the port is still replaced"
    )
    domain.removePersistentDomain(forName: sleepSuite)
  } else {
    checks.check(false, "a throwaway defaults domain could not be created")
  }

  // The panel draws the fact, not the preference.
  checks.check(!HarnessSnapshot(phase: .listening).awake, "a snapshot is not awake unless told")
  checks.check(Fixtures.snapshot(for: .listening, copy: en).awake, "a managed server shows the awake badge")
  checks.check(
    !Fixtures.snapshot(for: .listeningExternal, copy: en).awake,
    "an external server holds no assertion"
  )
  checks.check(
    !Fixtures.snapshot(for: .listeningHandoff, copy: en).awake,
    "a handed-off server holds no assertion"
  )
  checks.check(!Fixtures.snapshot(for: .stopped, copy: en).awake, "a stopped server is not awake")

  // MARK: - 0.6.0 · token hygiene

  let launchLine = "dsh web: http://127.0.0.1:3080/?token=s3cr3tAbC123"
  let redactedLine = LogRedaction.redact(launchLine)
  checks.equal(redactedLine, "dsh web: http://127.0.0.1:3080/?token=…", "the launch line loses its token")
  checks.check(!redactedLine.contains("s3cr3tAbC123"), "the token value is gone")
  checks.equal(LogRedaction.redact(redactedLine), redactedLine, "redaction is idempotent")
  checks.equal(
    LogRedaction.redact("?a=1&token=xyz&b=2"),
    "?a=1&token=…&b=2",
    "a token in the middle keeps the rest of the query"
  )
  checks.equal(LogRedaction.redact("TOKEN=abc"), "TOKEN=…", "the key is matched case-insensitively")
  checks.equal(LogRedaction.redact("mytoken=abc"), "mytoken=abc", "a word ending in token is not a key")
  checks.equal(LogRedaction.redact("token="), "token=", "an empty value has nothing to hide")
  checks.equal(
    LogRedaction.redact("(http://h:1/?token=abc)."),
    "(http://h:1/?token=…).",
    "punctuation after the URL survives"
  )
  checks.equal(
    LogRedaction.redact("token=a token=b"),
    "token=… token=…",
    "every token on the line is masked"
  )
  checks.equal(LogRedaction.redact("no secret here"), "no secret here", "a clean line is untouched")
  checks.equal(
    LogRedaction.redactedURL("http://127.0.0.1:3080/?token=abc&profile=web"),
    "http://127.0.0.1:3080/?token=…&profile=web",
    "redactedURL keeps other parameters"
  )
  checks.equal(
    LogRedaction.urlWithoutToken("http://127.0.0.1:3080/?token=abc&profile=web"),
    "http://127.0.0.1:3080/?profile=web",
    "the copyable link drops only the credential"
  )
  checks.equal(
    LogRedaction.urlWithoutToken("http://127.0.0.1:3080/?token=abc"),
    "http://127.0.0.1:3080/",
    "a link with only a token becomes the bare address"
  )
  checks.check(LogRedaction.carriesToken("http://h/?token=a"), "a token is noticed")
  checks.check(!LogRedaction.carriesToken("http://h/?profile=web"), "no token, nothing to notice")
  checks.check(
    !Fixtures.log().contains { $0.text.contains("{{SECRET_6xmk2p4v}}") },
    "the reviewed fixture carries no token"
  )
  checks.check(
    Fixtures.log().first?.text.contains("token=…") == true,
    "the reviewed fixture shows the masked form"
  )

  // The handoff note is written to disk and read back on the next launch.
  let tokenHandoffSuite = "dev.dsh.bar.check.handoff.\(UUID().uuidString)"
  if let domain = UserDefaults(suiteName: tokenHandoffSuite) {
    HandoffStore.save(
      HandoffRecord(pid: 42, port: 3099, startedAt: Date(), launchURL: "http://127.0.0.1:3099/?token=abc"),
      to: domain
    )
    let stored = HandoffStore.load(from: domain)
    checks.check(stored?.launchURL?.contains("token=…") == true, "the handoff note stores a masked token")
    checks.check(stored?.launchURL?.contains("abc") == false, "the handoff note stores no token value")
    checks.check(stored?.pid == 42, "the handoff note still identifies the process")
    domain.removePersistentDomain(forName: tokenHandoffSuite)
  } else {
    checks.check(false, "a throwaway defaults domain could not be created")
  }

  // MARK: - 0.6.0 · launch flags

  let defaultsFlags = WebLaunchFlags.empty
  checks.equal(
    defaultsFlags.arguments(profile: "web", port: 3099),
    ["--profile", "web", "--no-open", "--port", "3099"],
    "default flags are exactly the 0.5.0 argv"
  )
  checks.equal(
    defaultsFlags.arguments(profile: "web", port: 0),
    ["--profile", "web", "--no-open"],
    "an auto port sends no --port"
  )
  checks.check(defaultsFlags.isDefault, "empty flags are the default")
  checks.check(!defaultsFlags.usesTLS, "no certificate, no TLS")
  checks.check(!defaultsFlags.bindsBeyondLoopback, "no host, loopback only")

  let lanFlags = WebLaunchFlags(
    host: "192.168.1.10",
    publicURL: "https://dsh.example.com/",
    trustedHosts: ["dsh.example.com", "[::1]:8080"],
    tlsCertPath: "/tmp/cert.pem",
    tlsKeyPath: "/tmp/key.pem",
    patches: ["/tmp/a.yml", "/tmp/b.yml"]
  )
  checks.equal(
    lanFlags.arguments(profile: "web", port: 3080),
    [
      "--profile", "web", "--no-open", "--port", "3080",
      "--host", "192.168.1.10",
      "--public-url", "https://dsh.example.com/",
      "--trusted-host", "dsh.example.com",
      "--trusted-host", "[::1]:8080",
      "--tls-cert", "/tmp/cert.pem",
      "--tls-key", "/tmp/key.pem",
      "--patch", "/tmp/a.yml",
      "--patch", "/tmp/b.yml",
    ],
    "every flag reaches argv, in one order"
  )
  checks.check(lanFlags.usesTLS, "a certificate pair turns TLS on")
  checks.check(lanFlags.bindsBeyondLoopback, "a LAN address is beyond loopback")
  checks.check(!lanFlags.isDefault, "flags are not the default")

  checks.equal(WebLaunchFlags.hostProblem(""), nil, "an empty host is not a problem")
  checks.equal(WebLaunchFlags.hostProblem("127.0.0.1"), nil, "loopback is a literal")
  checks.equal(WebLaunchFlags.hostProblem("192.168.1.10"), nil, "a LAN address is a literal")
  checks.equal(WebLaunchFlags.hostProblem("::1"), nil, "an IPv6 loopback is a literal")
  checks.equal(WebLaunchFlags.hostProblem("0.0.0.0"), .wildcardHost("0.0.0.0"), "wildcard v4 is refused")
  checks.equal(WebLaunchFlags.hostProblem("::"), .wildcardHost("::"), "wildcard v6 is refused")
  checks.equal(WebLaunchFlags.hostProblem("*"), .wildcardHost("*"), "star is refused")
  checks.equal(
    WebLaunchFlags.hostProblem("example.com"),
    .invalidHost("example.com"),
    "a host name is not an address"
  )
  checks.equal(
    WebLaunchFlags.hostProblem("127.0.0.999"),
    .invalidHost("127.0.0.999"),
    "an impossible octet is refused"
  )

  checks.check(WebLaunchFlags.isLoopback("127.0.0.1"), "127.0.0.1 is loopback")
  checks.check(WebLaunchFlags.isLoopback("127.9.9.9"), "the whole 127/8 is loopback")
  checks.check(WebLaunchFlags.isLoopback("::1"), "::1 is loopback")
  checks.check(WebLaunchFlags.isLoopback("localhost"), "localhost is loopback")
  checks.check(!WebLaunchFlags.isLoopback("192.168.1.10"), "a LAN address is not loopback")

  checks.check(WebLaunchFlags.isPublicURL("https://dsh.example.com/"), "https is a public URL")
  checks.check(WebLaunchFlags.isPublicURL("http://10.0.0.2:8080"), "http is a public URL")
  checks.check(!WebLaunchFlags.isPublicURL("dsh.example.com"), "a bare host is not a URL")
  checks.check(!WebLaunchFlags.isPublicURL("ftp://dsh.example.com"), "another scheme is not a URL")
  checks.check(WebLaunchFlags.isTrustedHost("dsh.example.com"), "a host is trusted")
  checks.check(WebLaunchFlags.isTrustedHost("dsh.example.com:8080"), "host:port is trusted")
  checks.check(WebLaunchFlags.isTrustedHost("[::1]:8080"), "a bracketed IPv6 authority is trusted")
  checks.check(!WebLaunchFlags.isTrustedHost("https://dsh.example.com"), "a scheme is not an authority")
  checks.check(!WebLaunchFlags.isTrustedHost("dsh.example.com/ui"), "a path is not an authority")
  checks.check(!WebLaunchFlags.isTrustedHost("dsh.example.com:0"), "port 0 is not an authority")

  let flagFiles: (String) -> Bool = { $0.hasPrefix("/tmp/ok") }
  checks.equal(
    WebLaunchFlags(host: "0.0.0.0").firstProblem(fileExists: flagFiles),
    .wildcardHost("0.0.0.0"),
    "a wildcard host is the first problem"
  )
  checks.equal(
    WebLaunchFlags(tlsCertPath: "/tmp/ok.pem").firstProblem(fileExists: flagFiles),
    .tlsNeedsBoth,
    "one half of the pair is refused"
  )
  checks.equal(
    WebLaunchFlags(tlsCertPath: "/tmp/ok.pem", tlsKeyPath: "/tmp/gone.pem")
      .firstProblem(fileExists: flagFiles),
    .missingFile(field: .tlsKey, path: "/tmp/gone.pem"),
    "a missing key is named"
  )
  checks.equal(
    WebLaunchFlags(patches: ["/tmp/ok.yml", "/tmp/gone.yml"]).firstProblem(fileExists: flagFiles),
    .missingFile(field: .patch, path: "/tmp/gone.yml"),
    "a missing patch is named"
  )
  checks.equal(
    WebLaunchFlags(patches: [""]).firstProblem(fileExists: flagFiles),
    .emptyPatch,
    "an empty patch path is refused"
  )
  checks.check(
    WebLaunchFlags(host: "example.com", publicURL: "nope").problems(fileExists: flagFiles).count == 2,
    "each bad field reports once"
  )
  checks.check(
    WebLaunchFlags(host: "0.0.0.0", publicURL: "nope").firstProblem(fileExists: flagFiles)?.field == .host,
    "the first problem is the first row"
  )

  let flagsSuite = "dev.dsh.bar.check.flags.\(UUID().uuidString)"
  if let domain = UserDefaults(suiteName: flagsSuite) {
    let fresh = BarPreferences.load(from: domain)
    checks.check(fresh.launchFlags.isDefault, "an upgrade sends no new flags")
    checks.equal(fresh.trustedHosts, [], "no trusted hosts by default")
    var saved = fresh
    saved.launchHost = " 192.168.1.10 "
    saved.publicURL = " https://dsh.example.com/ "
    saved.trustedHosts = BarPreferences.normalizeTrustedHosts(["a.example, b.example  a.example"])
    saved.tlsCertPath = "~/cert.pem"
    saved.patchPaths = BarPreferences.normalizePaths(["/tmp/a.yml", "/tmp/a.yml"])
    saved.save(to: domain)
    let loaded = BarPreferences.load(from: domain)
    checks.equal(loaded.launchHost, "192.168.1.10", "the bind host is trimmed")
    checks.equal(loaded.publicURL, "https://dsh.example.com/", "the public URL is trimmed")
    checks.equal(loaded.trustedHosts, ["a.example", "b.example"], "trusted hosts split and dedupe")
    checks.equal(loaded.trustedHostsText, "a.example, b.example", "the field text joins them")
    checks.check(loaded.tlsCertPath?.hasPrefix("/") == true, "the certificate path is expanded")
    checks.check(loaded.tlsCertPath?.hasSuffix("/cert.pem") == true, "the certificate path is kept")
    checks.equal(loaded.patchPaths.count, 1, "patch paths dedupe")
    checks.equal(
      loaded.replacing(port: 3099).launchHost,
      "192.168.1.10",
      "changing the port keeps the flags"
    )
    checks.check(!loaded.launchFlags.isDefault, "saved flags are not the default")
    var cleared = loaded
    cleared.setLaunchFlags(.empty)
    checks.check(cleared.launchFlags.isDefault, "clearing the flags goes back to the 0.5.0 argv")
    checks.equal(BarPreferences.normalizeHost("   "), nil, "a blank host is no host")
    domain.removePersistentDomain(forName: flagsSuite)
  } else {
    checks.check(false, "a throwaway defaults domain could not be created")
  }

  let lanSnapshot = HarnessSnapshot(phase: .stopped, port: 3080, bindHost: "192.168.1.10")
  checks.equal(lanSnapshot.address, "192.168.1.10:3080", "before a start the readout shows the bind address")
  checks.check(lanSnapshot.sharesOnLAN, "a LAN bind is shared")
  checks.check(
    !HarnessSnapshot(phase: .stopped, bindHost: "127.0.0.1").sharesOnLAN,
    "loopback is not shared"
  )
  checks.check(
    !HarnessSnapshot(phase: .listening, host: "10.0.0.2").sharesOnLAN,
    "no configured host, no badge"
  )
  checks.check(!HarnessSnapshot(phase: .listening).secure, "TLS is off unless told")
  checks.equal(
    HarnessSnapshot(phase: .listening, host: "192.168.1.10", port: 3080, bindHost: "192.168.1.10").address,
    "192.168.1.10:3080",
    "while serving the printed host wins"
  )
  let lanFixture = Fixtures.snapshot(for: .listeningLAN, copy: en)
  checks.check(lanFixture.sharesOnLAN, "the LAN fixture shows the LAN word")
  checks.check(lanFixture.secure, "the LAN fixture shows the TLS word")
  checks.check(
    !Fixtures.snapshot(for: .listening, copy: en).sharesOnLAN,
    "the plain listening fixture is loopback"
  )

  let flagFailure = HarnessFailure(kind: .launchFlags(.wildcardHost("0.0.0.0")))
  checks.check(flagFailure.recovery == nil, "a bad flag has no one-click repair")
  checks.equal(
    HarnessFailure(kind: .launchFlags(.missingFile(field: .tlsCert, path: "/tmp/c.pem"))).path,
    "/tmp/c.pem",
    "the failure names the missing file"
  )
  checks.equal(en.diagnosis(flagFailure).title, "A launch flag is unusable.", "en flag diagnosis title")
  checks.check(en.diagnosis(flagFailure).body.contains("0.0.0.0"), "the diagnosis quotes the address")
  checks.check(zh.diagnosis(flagFailure).title.contains("启动参数"), "zh flag diagnosis title")

  checks.equal(en.tabLaunch, "Launch", "en launch tab")
  checks.equal(zh.tabLaunch, "启动", "zh launch tab")
  checks.equal(en.lanBadge, "LAN", "en LAN word")
  checks.equal(zh.lanBadge, "局域网", "zh LAN word")
  checks.equal(en.tlsBadge, "TLS", "en TLS word")
  checks.equal(en.networkBadge(lan: true, tls: true), "LAN · TLS", "en combined network word")
  checks.equal(zh.networkBadge(lan: true, tls: false), "局域网", "zh LAN word alone")
  checks.equal(zh.networkBadge(lan: false, tls: true), "TLS", "zh TLS word alone")
  checks.equal(zh.networkBadge(lan: false, tls: false), nil, "no flags, no word")
  checks.equal(zh.copyLinkRedacted, "复制不含凭证的链接", "zh redacted link action")
  checks.equal(en.copyLinkRedacted, "Copy link without the token", "en redacted link action")
  checks.check(en.launchFlagProblem(.tlsNeedsBoth).contains("together"), "en pair problem is explained")
  checks.check(zh.launchFlagProblem(.tlsNeedsBoth).contains("一起"), "zh pair problem is explained")
  checks.check(
    en.launchFlagProblem(.missingFile(field: .patch, path: "/tmp/x.yml")).contains("/tmp/x.yml"),
    "a missing file is quoted"
  )
  checks.check(
    zh.launchFlagProblem(.invalidPublicURL("nope")).contains("nope"),
    "zh quotes the bad URL"
  )

  checks.equal(PortProbe.normalizedHost(""), "127.0.0.1", "an empty host probes loopback")
  checks.equal(PortProbe.normalizedHost("localhost"), "127.0.0.1", "localhost probes loopback")
  checks.equal(PortProbe.normalizedHost("192.168.1.10"), "192.168.1.10", "a literal passes through")
  checks.check(PortProbe.numericAddress("127.0.0.1", port: 3080)?.family == AF_INET, "IPv4 resolves")
  checks.check(PortProbe.numericAddress("::1", port: 3080)?.family == AF_INET6, "IPv6 resolves")
  checks.check(
    PortProbe.numericAddress("example.com", port: 3080) == nil,
    "a host name does not resolve numerically"
  )

  // MARK: - 0.7.0 · crash watchdog

  let w0 = Date(timeIntervalSince1970: 1_800_000_000)
  checks.equal(CrashWatchdog.delay(attempt: 1), 1, "the first retry is one second")
  checks.equal(CrashWatchdog.delay(attempt: 2), 2, "the second retry backs off")
  checks.equal(CrashWatchdog.delay(attempt: 3), 4, "the third retry backs off")
  checks.equal(CrashWatchdog.delay(attempt: 4), 8, "the fourth retry hits the cap")
  checks.equal(CrashWatchdog.delay(attempt: 9), 8, "the cap holds")
  checks.equal(CrashWatchdog.decide(attempts: [], now: w0), .restart(attempt: 1, delay: 1), "a fresh budget restarts at once")
  checks.equal(
    CrashWatchdog.decide(attempts: [w0.addingTimeInterval(-5)], now: w0),
    .restart(attempt: 2, delay: 2),
    "a second crash inside the window counts"
  )
  checks.equal(
    CrashWatchdog.decide(
      attempts: [w0.addingTimeInterval(-30), w0.addingTimeInterval(-20), w0.addingTimeInterval(-10)],
      now: w0
    ),
    .giveUp(attempts: 3),
    "three attempts inside the window exhaust the budget"
  )
  checks.equal(
    CrashWatchdog.decide(
      attempts: [w0.addingTimeInterval(-300), w0.addingTimeInterval(-280), w0.addingTimeInterval(-260)],
      now: w0
    ),
    .restart(attempt: 1, delay: 1),
    "old attempts fall out of the window"
  )
  checks.equal(
    CrashWatchdog.decide(
      attempts: [w0.addingTimeInterval(-300), w0.addingTimeInterval(-200), w0.addingTimeInterval(-100)],
      now: w0
    ),
    .restart(attempt: 2, delay: 2),
    "an attempt outside the window stops counting, the one inside still does"
  )
  checks.equal(CrashWatchdog.recentAttempts([w0.addingTimeInterval(-400)], now: w0).count, 0, "recentAttempts filters")

  // The reducer: listening → crash → restarting → starting → listening.
  let watchBase = HarnessState(
    snapshot: HarnessSnapshot(phase: .listening, port: 3080, owner: .dshBar, hasLaunchURL: true)
  )
  let retryTarget = RetryTarget(port: 3080, profile: "web")
  var watching = watchBase
  watching.retryTarget = retryTarget
  let (crash1, crash1Commands) = HarnessReducer.reduce(
    watching,
    .exited(code: 1, signal: nil),
    language: .en,
    now: w0
  )
  checks.equal(crash1.snapshot.phase, .restarting, "a crash while serving enters restarting")
  checks.equal(crash1.snapshot.restartAttempt, 1, "the first retry is attempt 1")
  checks.equal(crash1.snapshot.restartDelay, 1, "the first retry waits one second")
  checks.equal(crash1.attempts.count, 1, "the attempt is remembered")
  checks.equal(crash1.snapshot.owner, .dshBar, "the retry keeps the owner")
  checks.check(crash1.snapshot.busy, "a restart is busy")
  checks.check(crash1.snapshot.isRestarting, "the snapshot knows it is restarting")
  checks.check(!crash1.snapshot.showsLog, "a restarting panel shows no log tail")
  checks.equal(
    crash1Commands,
    [.stopUptime, .disarmReadyTimeout, .scheduleRestart(delay: 1)],
    "the first crash schedules the first retry"
  )
  checks.equal(
    HarnessReducer.reduce(crash1, .restartDue, language: .en, now: w0).0.snapshot.phase,
    .starting,
    "the timer starts the server again"
  )
  let (dueState, dueCommands) = HarnessReducer.reduce(crash1, .restartDue, language: .en, now: w0)
  checks.equal(dueCommands, [.writeLogSeparator, .restartNow(port: 3080)], "a retry writes a separator and asks to spawn")
  checks.equal(dueState.snapshot.restartAttempt, 1, "the attempt number survives into the start")
  checks.equal(dueState.snapshot.restartDelay, nil, "the delay is cleared once the wait is over")
  checks.check(dueState.retrying, "the start is the watchdog's")

  let relaunched = LaunchReport(url: "http://127.0.0.1:3080/?token=t", host: "127.0.0.1", port: 3080, token: "t")
  let (landed, _) = HarnessReducer.reduce(dueState, .launch(.ready(relaunched)), language: .en, now: w0)
  checks.equal(landed.snapshot.phase, .listening, "a successful retry is listening again")
  checks.equal(landed.snapshot.restartAttempt, nil, "a successful retry clears the attempt")
  checks.check(!landed.snapshot.busy, "a successful retry stops being busy")

  // A start by hand starts a fresh budget.
  let (manual, _) = HarnessReducer.reduce(
    crash1,
    .start(port: 3080, profile: "web"),
    language: .en,
    now: w0.addingTimeInterval(3)
  )
  checks.equal(manual.attempts, [], "a manual start resets the crash budget")
  checks.equal(manual.snapshot.phase, .starting, "a manual start from a pending restart starts")
  checks.equal(manual.snapshot.restartAttempt, nil, "a manual start is not a retry")

  // A crash during startup is a failure, not a watchdog job.
  let startingState = HarnessState(snapshot: HarnessSnapshot(phase: .starting, port: 3080))
  let (startupCrash, startupCommands) = HarnessReducer.reduce(
    startingState,
    .exited(code: 1, signal: nil),
    language: .en,
    now: w0
  )
  checks.equal(startupCrash.snapshot.phase, .failed, "a crash during startup fails the start")
  checks.check(!startupCommands.contains(.scheduleRestart(delay: 1)), "a startup crash schedules no retry")

  // Auto restart off: the same crash lands in failed.
  let (noRestart, noRestartCommands) = HarnessReducer.reduce(
    watching,
    .exited(code: 1, signal: nil),
    language: .en,
    now: w0,
    autoRestart: false
  )
  checks.equal(noRestart.snapshot.phase, .failed, "with the watchdog off a crash just fails")
  checks.check(!noRestartCommands.contains(.scheduleRestart(delay: 1)), "with the watchdog off nothing is scheduled")

  // Cancel during a restart: stopped, nothing spawns.
  let (cancelled, watchdogCancelCommands) = HarnessReducer.reduce(crash1, .cancel, language: .en, now: w0)
  checks.equal(cancelled.snapshot.phase, .stopped, "cancel during a restart stops")
  checks.equal(watchdogCancelCommands, [.cancelRestart, .disarmReadyTimeout], "cancel tears the timer down")
  checks.equal(cancelled.snapshot.restartAttempt, nil, "cancel clears the attempt")
  checks.equal(
    HarnessReducer.reduce(cancelled, .restartDue, language: .en, now: w0).0.snapshot.phase,
    .stopped,
    "a late timer cannot start a cancelled restart"
  )
  let (abandoned, abandonCommands) = HarnessReducer.reduce(crash1, .restartAbandoned, language: .en, now: w0)
  checks.equal(abandoned.snapshot.phase, .failed, "abandoning a restart fails")
  checks.equal(abandonCommands, [.cancelRestart], "abandoning cancels the timer")

  // The budget runs out.
  var spent = watching
  spent.attempts = [w0.addingTimeInterval(-3), w0.addingTimeInterval(-2), w0.addingTimeInterval(-1)]
  let (gaveUp, gaveUpCommands) = HarnessReducer.reduce(spent, .exited(code: 1, signal: nil), language: .en, now: w0)
  checks.equal(gaveUp.snapshot.phase, .failed, "an exhausted budget fails")
  checks.equal(gaveUp.gaveUpAfter, 3, "the give-up records how many tries it made")
  checks.equal(gaveUp.snapshot.restartAttempt, nil, "a give-up clears the attempt")
  checks.check(!gaveUpCommands.contains(.scheduleRestart(delay: 1)), "a give-up schedules nothing")

  // A second exit for the same crash cannot restart twice.
  let (twice, twiceCommands) = HarnessReducer.reduce(crash1, .exited(code: 1, signal: nil), language: .en, now: w0)
  checks.equal(twice.snapshot.phase, .restarting, "the restarting state survives a duplicate exit")
  checks.equal(twiceCommands, [.stopUptime, .disarmReadyTimeout], "a duplicate exit schedules nothing")

  // Copy for the state.
  checks.equal(en.stateWord(.restarting), "Restarting…", "en restarting word")
  checks.equal(zh.stateWord(.restarting), "正在重启…", "zh restarting word")
  checks.equal(en.duration(0), "up 0s", "duration still formats")
  checks.equal(
    en.readoutSide(Fixtures.snapshot(for: .restarting, copy: en)),
    "retry 2 · in 4s",
    "en restart readout names the attempt and the wait"
  )
  checks.check(
    zh.readoutSide(Fixtures.snapshot(for: .restarting, copy: zh))?.contains("第 2 次") == true,
    "zh restart readout names the attempt"
  )
  checks.check(
    en.restartNote(Fixtures.snapshot(for: .restarting, copy: en)).contains("Restart 2 of 3"),
    "en restart note spells out the budget"
  )
  checks.check(
    zh.restartNote(Fixtures.snapshot(for: .restarting, copy: zh)).contains("共 3 次"),
    "zh restart note spells out the budget"
  )
  checks.equal(en.secondaryLabel(Fixtures.snapshot(for: .restarting, copy: en)), "Cancel", "a restart can be cancelled")
  checks.equal(zh.primaryLabel(Fixtures.snapshot(for: .restarting, copy: zh)), "正在重启…", "zh restarting primary label")

  // MARK: - 0.7.0 · notifications

  let live = HarnessSnapshot(phase: .listening, port: 3080, owner: .dshBar, hasLaunchURL: true)
  let crashed = HarnessSnapshot(phase: .failed, failure: HarnessFailure(kind: .exited(code: 1)))
  let startingFixture = HarnessSnapshot(phase: .starting)
  let stoppingFixture = HarnessSnapshot(phase: .stopping)
  checks.equal(NotificationPolicy.event(previous: startingFixture, next: crashed), .startFailed(HarnessFailure(kind: .exited(code: 1))), "a failed start notifies")
  checks.equal(
    NotificationPolicy.event(previous: live, next: crashed),
    .crashed(failure: HarnessFailure(kind: .exited(code: 1)), restarting: false, attempt: nil),
    "a crash notifies"
  )
  checks.equal(
    NotificationPolicy.event(previous: live, next: crash1.snapshot),
    .crashed(failure: HarnessFailure(kind: .exited(code: 1)), restarting: true, attempt: 1),
    "a crash the watchdog will retry says so"
  )
  checks.equal(
    NotificationPolicy.event(previous: crash1.snapshot, next: gaveUp.snapshot),
    .restartGaveUp(attempts: 1),
    "a give-up notifies"
  )
  checks.equal(
    NotificationPolicy.event(previous: stoppingFixture, next: crashed),
    .stopFailed(HarnessFailure(kind: .exited(code: 1))),
    "a failed stop notifies"
  )
  checks.equal(NotificationPolicy.event(previous: live, next: live), nil, "no change, no notification")
  checks.equal(
    NotificationPolicy.event(previous: HarnessSnapshot(phase: .stopped), next: crashed),
    nil,
    "a panel reopened on a failure stays quiet"
  )
  checks.equal(
    NotificationPolicy.event(previous: live, next: HarnessSnapshot(phase: .stopping)),
    nil,
    "pressing stop does not notify"
  )
  checks.equal(NotificationPolicy.identifier(.startFailed(HarnessFailure(kind: .timeout(seconds: 30)))), "dev.dsh.bar.start-failed", "a failed start replaces its own notification")
  checks.equal(
    NotificationPolicy.identifier(.crashed(failure: HarnessFailure(kind: .exited(code: 1)), restarting: true, attempt: 2)),
    "dev.dsh.bar.crashed",
    "crash notifications share one identifier"
  )
  checks.check(en.notificationTitle(.crashed(failure: .init(kind: .exited(code: 1)), restarting: true, attempt: 1)).contains("restarting"), "en crash title says restarting")
  checks.check(zh.notificationTitle(.restartGaveUp(attempts: 3)).contains("已停止"), "zh give-up title")
  checks.check(zh.notificationBody(.restartGaveUp(attempts: 3)).contains("3"), "zh give-up body names the budget")
  checks.check(en.notificationBody(.startFailed(.init(kind: .portInUse(port: 3099)))).contains("3099"), "en failure body reuses the diagnosis")
  checks.equal(en.notificationState(.allowed), "allowed", "en allowed")
  checks.equal(zh.notificationState(.denied), "已被系统拒绝", "zh denied")
  checks.equal(en.notificationState(.notDetermined), "not asked yet", "en not asked")
  checks.equal(en.notificationState(.unavailable), "unavailable", "en unavailable")

  // The preferences round-trip.
  let watchdogSuite = "dev.dsh.bar.check.watchdog.\(UUID().uuidString)"
  if let domain = UserDefaults(suiteName: watchdogSuite) {
    let fresh = BarPreferences.load(from: domain)
    checks.check(fresh.autoRestart, "a fresh domain restarts after a crash")
    checks.check(fresh.notify, "a fresh domain notifies")
    var off = fresh
    off.autoRestart = false
    off.notify = false
    off.save(to: domain)
    let reloaded = BarPreferences.load(from: domain)
    checks.check(!reloaded.autoRestart, "the watchdog switch survives")
    checks.check(!reloaded.notify, "the notification switch survives")
    checks.equal(reloaded.replacing(port: 3099).autoRestart, false, "changing the port keeps the watchdog setting")
    domain.removePersistentDomain(forName: watchdogSuite)
  } else {
    checks.check(false, "a throwaway defaults domain could not be created")
  }

  return checks.report()
}

MainActor.assumeIsolated {
  exit(runChecks())
}
