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

  // MARK: Spin arc

  // The spin is a shape layer of our own, anchored at its centre. Assert the path
  // is the arc the static glyph draws, centred in the 18pt box.
  let spinArc = StatusIcon.spinArcPath()
  checks.check(!spinArc.isEmpty, "the spin arc is a real path")
  let arcBox = spinArc.boundingBox
  checks.check(arcBox.width > 9.5 && arcBox.width < 11, "the spin arc spans the glyph")
  checks.check(arcBox.midX > 8.9 && arcBox.midX < 9.1, "the spin arc is centred horizontally")
  checks.check(arcBox.midY > 8.9 && arcBox.midY < 9.1, "the spin arc is centred vertically")

  // The listening glyph is two shapes so the dot can breathe alone.
  let listenRing = StatusIcon.listeningRingPath()
  let listenDot = StatusIcon.listeningDotPath()
  checks.check(abs(listenRing.boundingBox.width - 11.2) < 0.2, "the listening ring is 11.2 wide")
  checks.check(abs(listenDot.boundingBox.width - 4.8) < 0.2, "the listening dot is 4.8 wide")
  checks.check(abs(listenDot.boundingBox.midX - 9) < 0.1, "the dot is centred")

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

  return checks.report()
}

MainActor.assumeIsolated {
  exit(runChecks())
}
