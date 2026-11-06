import AppKit
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
  checks.equal(crashState.snapshot.phase, .failed, "a crash after ready fails")
  checks.equal(crashState.snapshot.failure?.kind, .exited(code: 1), "the crash keeps its code")
  checks.equal(crashState.snapshot.lastRun, "just now", "the crash records when it ran")
  checks.check(!crashState.snapshot.hasLaunchURL, "a crash loses the URL")
  checks.equal(crashCommands, [.stopUptime, .disarmReadyTimeout], "a crash stops the clock")

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
    let record = HandoffRecord(pid: 4326, port: 3099, startedAt: Date(timeIntervalSince1970: 1_700_000_000), launchURL: "http://127.0.0.1:3099/?token=x")
    HandoffStore.save(record, to: domain)
    checks.equal(HandoffStore.load(from: domain), record, "a handoff record survives a relaunch")
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

  return checks.report()
}

MainActor.assumeIsolated {
  exit(runChecks())
}
