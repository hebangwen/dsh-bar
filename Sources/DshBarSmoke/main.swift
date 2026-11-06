import DshBarKit
import Foundation

/// End-to-end proof that the live path works without opening the GUI:
/// locate dsh → check the port → spawn → read the launch URL → talk to the
/// server → stop it → confirm the port is free.
///
///   swift run dshbar-smoke [--port 3099]
///
/// Port 3099 is the convention for Integration work; 3080 is refused because a
/// real session normally lives there.
@MainActor
enum Smoke {
  static func main() {
    let arguments = CommandLine.arguments
    let requested = value(for: "--port", in: arguments).flatMap(Int.init) ?? 3099
    // `--sleep` runs the power-assertion half; `--sleep off` only proves a disabled
    // policy stays silent.
    let sleepRun = arguments.contains("--sleep")
    let sleepWanted = (value(for: "--sleep", in: arguments) ?? "on") != "off"
    // `--flags` proves the optional argv reaches dsh: a bind address and a trusted
    // authority, both loopback, so nothing leaves the machine.
    let flagRun = arguments.contains("--flags")
    let flags = flagRun
      ? WebLaunchFlags(host: "127.0.0.1", trustedHosts: ["127.0.0.1:\(requested)"])
      : .empty
    // `--watchdog` runs the crash → retry half without the app: a real dsh is
    // killed with SIGKILL while serving, and the reducer's decisions are driven by
    // hand through the same transitions `LiveBackend` performs.
    let watchdogRun = arguments.contains("--watchdog")
    // `--watchdog off` is one argument; `contains("--watchdog off")` would
    // silently enable the watchdog because the shell splits it into two.
    let watchdogOff = arguments.contains("--watchdog")
      && (value(for: "--watchdog", in: arguments) ?? "on") == "off"
    guard requested != 3080, (1...65535).contains(requested) else {
      print("refusing port \(requested): use something other than 3080, e.g. 3099")
      exit(1)
    }

    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
      print(condition ? "✓ \(message)" : "✗ \(message)")
      if !condition { failures.append(message) }
    }

    let environment = LoginShellEnvironment.resolve()
    print("environment: \(environment.source.rawValue) (\(environment.values.count) vars)")
    check(environment.values["PATH"]?.isEmpty == false, "environment has a PATH")

    let preferences = BarPreferences.load()
    let lookup = DshLocator.resolve(
      explicit: preferences.binaryPath,
      pathEnv: environment.values["PATH"],
      home: environment.values["HOME"] ?? NSHomeDirectory(),
      environmentOverride: ProcessInfo.processInfo.environment[DshLocator.environmentKey]
    )
    guard case let .found(detection) = lookup else {
      print("✗ dsh not found; tried:")
      if case let .missing(searched) = lookup {
        for path in searched { print("    \(path)") }
      }
      exit(1)
    }
    print("✓ dsh: \(detection.path) (\(detection.source.rawValue))")

    // Same PATH the app builds: dsh's own directory first, because that is where
    // the `node` matching this dsh lives. Without it the spawn dies inside
    // `/usr/bin/env` with "node: No such file or directory".
    var spawnEnvironment = environment.values
    spawnEnvironment["PATH"] = LoginShellEnvironment.runnablePath(
      forExecutable: detection.path,
      environment: spawnEnvironment
    )
    check(
      LoginShellEnvironment.hasNode(onPath: spawnEnvironment["PATH"]),
      "PATH resolves node for dsh (\(LoginShellEnvironment.nodePath(onPath: spawnEnvironment["PATH"]) ?? "none"))"
    )

    if watchdogRun {
      exit(
        watchdog(
          environment: spawnEnvironment,
          detection: detection,
          profile: preferences.profile,
          port: requested,
          enabled: !watchdogOff
        )
      )
    }

    if arguments.contains("--external") {
      exit(takeOver(environment: spawnEnvironment, detection: detection, port: requested))
    }

    let before = PortProbe.probe(host: flags.host ?? "127.0.0.1", port: requested)
    guard before == .free else {
      print("✗ port \(requested) is not free (\(before)); stop it or pick another port")
      exit(1)
    }
    print("✓ port \(requested) is free")

    // Armed after the spawn, asserted while the server is up, and expected to
    // disappear on its own when the server stops.
    let sleepGuard: SleepGuard? = sleepRun ? SleepGuard() : nil
    sleepGuard?.onEvent = { print("  · sleep: \($0)") }
    var pendingSleepStop = false

    var report: LaunchReport?
    var exitCode: Int32?
    var failureDetail: String?

    let spawnArguments = flags.arguments(profile: preferences.profile, port: requested)
    if flagRun {
      print("· argv: \(spawnArguments.joined(separator: " "))")
      check(spawnArguments.contains("--host"), "the bind flag reaches the argv")
      check(spawnArguments.contains("--trusted-host"), "the trusted-host flag reaches the argv")
      check(spawnArguments.contains("--port"), "the port flag survives next to them")
    }
    let child: ChildProcess
    do {
      child = try ChildProcess(
        executable: detection.path,
        arguments: spawnArguments,
        environment: spawnEnvironment
      )
    } catch {
      print("✗ spawn failed: \(error)")
      exit(1)
    }
    print("· spawned pid \(child.pid)")

    child.onLine = { _, text in
      switch LaunchOutput.classify(text) {
      case .ready(let parsed):
        report = parsed
      case .portInUse(let port):
        failureDetail = "port in use \(port.map(String.init) ?? "?")"
      case .startupFailed(let detail):
        failureDetail = detail ?? "startup failed"
      case .ignored:
        break
      }
    }
    child.onExit = { code, _ in
      exitCode = code ?? -1
    }

    let deadline = Date().addingTimeInterval(30)
    while report == nil, exitCode == nil, Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    guard let launch = report else {
      print("✗ no launch URL (exit \(exitCode.map(String.init) ?? "none"), \(failureDetail ?? "no detail"))")
      child.kill()
      exit(1)
    }
    check(launch.port == requested, "launch URL reports the requested port (\(launch.port))")
    if flagRun {
      check(launch.host == "127.0.0.1", "the printed URL follows the bind address (\(launch.host))")
    }
    check(!launch.token.isEmpty, "launch URL carries a token")
    print("✓ launch URL: \(launch.url)")

    let unauthenticated = fetch(bareRoot(of: launch.url))
    print("  bare root: \(unauthenticated.status) body=\(unauthenticated.body.prefix(60))")
    check(unauthenticated.status == 401, "the bare root answers 401")
    check(
      unauthenticated.body.hasPrefix(PortProbe.fingerprint),
      "the 401 body is the dsh fence"
    )
    let authenticated = fetch(launch.url)
    check(
      (300...399).contains(authenticated.status) || authenticated.status == 200,
      "the token URL is accepted (\(authenticated.status))"
    )

    if let sleepGuard {
      // Negative first: a disabled policy must not leave anything behind.
      sleepGuard.reconcile(policy: .off, watching: child.pid)
      _ = wait(seconds: 0.4) { !sleepGuard.status.isAsserting }
      check(!sleepGuard.status.isAsserting, "a disabled policy holds no assertion")
      check(
        caffeinateAssertions(for: child.pid).isEmpty,
        "a disabled policy leaves nothing in pmset"
      )

      // `--sleep off` stops the sleep half here; the rest is the normal run.
      if sleepWanted {
        sleepGuard.reconcile(policy: .whileListening, watching: child.pid)
        check(
          wait(seconds: 2.0) { sleepGuard.status.isAsserting },
          "the guard reports an assertion for pid \(child.pid)"
        )
        let listing = assertionsListing()
        let held = caffeinateAssertions(in: listing, for: child.pid)
        check(held.count == 1, "pmset lists exactly one caffeinate assertion for the dsh pid")
        check(
          held.first?.kind == SleepAssertion.Kind.idleSystem,
          "the assertion prevents idle system sleep"
        )
        check(
          held.allSatisfy { $0.kind != SleepAssertion.Kind.idleDisplay },
          "the assertion leaves display sleep alone, so the screen can still turn off"
        )
        check(held.first?.watchedPID == Int(child.pid), "the assertion names the dsh pid")
        // The real claim behind `-w`: the tool goes away with the server, without
        // this app doing anything.
        pendingSleepStop = true
      }
    }

    // The "quit and keep it running" claim, checked against the real process the
    // same way the next launch checks it: pid alive, command line is a dsh, port
    // answers with the fence. No record is written here — this is the verifier.
    let record = HandoffRecord(
      pid: child.pid,
      port: launch.port,
      startedAt: Date(),
      launchURL: launch.url
    )
    let liveInspection = HandoffVerifier.inspect(record)
    check(liveInspection.pidAlive, "the handoff record's pid is alive")
    check(liveInspection.portServesDsh, "the handoff record's port answers as a dsh")
    check(
      HandoffVerifier.verify(record, inspection: liveInspection) == .valid,
      "a live handoff verifies as valid"
    )

    child.terminate()
    let stopDeadline = Date().addingTimeInterval(5)
    while exitCode == nil, Date() < stopDeadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check(exitCode != nil, "the server exited after SIGTERM")

    if let sleepGuard, pendingSleepStop {
      check(
        wait(seconds: 3.0) { !sleepGuard.status.isAsserting },
        "the guard stops asserting once the dsh pid is gone (\(sleepGuard.status))"
      )
      check(
        caffeinateAssertions(for: child.pid).isEmpty,
        "caffeinate exited by itself; nothing is left in pmset"
      )
      sleepGuard.release()
    }
    if exitCode == nil {
      child.kill()
      _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
    }

    var freed = false
    let freeDeadline = Date().addingTimeInterval(3)
    while Date() < freeDeadline {
      if PortProbe.probe(port: requested) == .free {
        freed = true
        break
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    check(freed, "port \(requested) is free again")
    check(
      !HandoffVerifier.verify(record, inspection: HandoffVerifier.inspect(record)).isUsable,
      "a handoff pointing at a stopped server is not usable"
    )

    if failures.isEmpty {
      print("\n✓ smoke passed")
      exit(0)
    }
    print("\n✗ \(failures.count) smoke checks failed")
    exit(1)
  }


  /// The crash half of the watchdog, end to end with a real dsh: boot it, kill it
  /// with SIGKILL while it is serving, and drive the same reducer the app drives —
  /// `.exited` → `.restarting` → `.restartDue` → probe → spawn → `.launch(.ready)`.
  ///
  /// Nothing is faked except the timer: the delay is read from the state and then
  /// slept through, so what is proven is that a real dsh can be restarted on the
  /// same port and that the policy fires exactly once per transition.
  private static func watchdog(
    environment: [String: String],
    detection: DshDetection,
    profile: String,
    port: Int,
    enabled: Bool
  ) -> Int32 {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
      print(condition ? "✓ \(message)" : "✗ \(message)")
      if !condition { failures.append(message) }
    }

    guard PortProbe.probe(port: port) == .free else {
      print("✗ port \(port) is not free")
      return 1
    }

    /// Boot a dsh and come back once it printed its URL.
    func boot() -> (ChildProcess, LaunchReport)? {
      guard let child = try? ChildProcess(
        executable: detection.path,
        arguments: WebLaunchFlags.empty.arguments(profile: profile, port: port),
        environment: environment
      ) else { return nil }
      var report: LaunchReport?
      child.onLine = { _, text in
        if case .ready(let parsed) = LaunchOutput.classify(text) { report = parsed }
      }
      let deadline = Date().addingTimeInterval(30)
      while report == nil, child.isAlive, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
      }
      guard let report else {
        child.kill()
        return nil
      }
      return (child, report)
    }

    func waitForExit(_ child: ChildProcess, seconds: Double = 5) -> Bool {
      let deadline = Date().addingTimeInterval(seconds)
      while child.isAlive, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
      }
      return !child.isAlive
    }

    guard let (first, launch) = boot() else {
      print("✗ the first dsh never printed a URL")
      return 1
    }
    print("· pid \(first.pid) serving \(launch.url)")
    check(PortProbe.probe(port: port) == .dsh, "the port answers as a dsh before the crash")

    var state = HarnessState(snapshot: HarnessSnapshot(phase: .listening, port: port, owner: .dshBar, hasLaunchURL: true))
    state.retryTarget = RetryTarget(port: port, profile: profile)
    if !enabled {
      first.kill()
      _ = waitForExit(first)
      let (next, commands) = HarnessReducer.reduce(
        state,
        .exited(code: nil, signal: 9),
        language: .en,
        autoRestart: false
      )
      check(next.snapshot.phase == .failed, "with the watchdog off a crash is just a failure")
      check(!commands.contains(.scheduleRestart(delay: 1)), "with the watchdog off nothing is scheduled")
      return report(failures, "watchdog off")
    }

    // The crash: SIGKILL, so the app cannot have asked for it.
    first.kill()
    check(waitForExit(first), "the server died from SIGKILL")
    let (restarting, commands) = HarnessReducer.reduce(
      state,
      .exited(code: nil, signal: 9),
      language: .en,
      autoRestart: true
    )
    check(restarting.snapshot.phase == .restarting, "the crash enters restarting")
    check(restarting.snapshot.restartAttempt == 1, "it is the first retry")
    check(commands.contains(.scheduleRestart(delay: 1)), "the first retry is scheduled one second out")
    let crashedNotice = NotificationPolicy.event(previous: state.snapshot, next: restarting.snapshot)
    check(
      crashedNotice == .crashed(failure: HarnessFailure(kind: .exited(code: nil), detail: "signal 9"), restarting: true, attempt: 1),
      "the crash is a notification, and it says it is being retried"
    )

    // The wait, then the same probe → spawn path a hand start uses.
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(TimeInterval(restarting.snapshot.restartDelay ?? 1)))
    let (due, _) = HarnessReducer.reduce(restarting, .restartDue, language: .en, autoRestart: true)
    check(due.snapshot.phase == .starting, "the timer starts the server again")
    let portState = PortProbe.probe(port: port)
    check(portState == .free, "the port is free again after the SIGKILL")
    state = due

    guard let (second, relaunch) = boot() else {
      print("✗ the restart never printed a URL")
      return report(failures, "watchdog")
    }
    print("· pid \(second.pid) restored \(relaunch.url)")
    let (landed, _) = HarnessReducer.reduce(due, .launch(.ready(relaunch)), language: .en, autoRestart: true)
    check(landed.snapshot.phase == .listening, "the restart lands back in listening")
    check(landed.snapshot.restartAttempt == nil, "a successful restart clears the attempt")
    check(landed.snapshot.port == port, "the restart keeps the port")
    check(PortProbe.probe(port: port) == .dsh, "the restarted server answers as a dsh")

    // An intentional stop notifies nobody.
    let (stopping, _) = HarnessReducer.reduce(landed, .stopRequested, language: .en, autoRestart: true)
    check(
      NotificationPolicy.event(previous: landed.snapshot, next: stopping.snapshot) == nil,
      "pressing stop is not a notification"
    )

    second.terminate()
    _ = waitForExit(second)
    check(PortProbe.probe(port: port) == .free, "port \(port) is free again")
    return report(failures, "watchdog")
  }

  private static func report(_ failures: [String], _ name: String) -> Int32 {
    if failures.isEmpty {
      print("\n✓ \(name) passed")
      return 0
    }
    print("\n✗ \(failures.count) \(name) checks failed")
    return 1
  }

  /// The take-over half of the external-instance flow: start a server the way a
  /// terminal would, then stop it through `ExternalInstance` — lsof for the pid,
  /// `ps` to confirm the command line, SIGTERM to the group — which is exactly
  /// what the panel does before it restarts the server under its own control.
  private static func takeOver(
    environment: [String: String],
    detection: DshDetection,
    port: Int
  ) -> Int32 {
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) {
      print(condition ? "✓ \(message)" : "✗ \(message)")
      if !condition { failures.append(message) }
    }

    guard PortProbe.probe(port: port) == .free else {
      print("✗ port \(port) is not free")
      return 1
    }

    var ready: LaunchReport?
    var exitCode: Int32?
    let child: ChildProcess
    do {
      child = try ChildProcess(
        executable: detection.path,
        arguments: ["--profile", "web", "--no-open", "--port", "\(port)"],
        environment: environment
      )
    } catch {
      print("✗ spawn failed: \(error)")
      return 1
    }
    child.onLine = { _, text in
      if case let .ready(report) = LaunchOutput.classify(text) { ready = report }
    }
    child.onExit = { code, _ in
      exitCode = code ?? -1
    }

    let deadline = Date().addingTimeInterval(30)
    while ready == nil, exitCode == nil, Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check(ready != nil, "the unsolicited instance is listening")
    check(child.pid > 0, "it has a pid")

    guard let pid = ExternalInstance.listeningPID(port: port) else {
      check(false, "lsof names the listener on \(port)")
      child.kill()
      return 1
    }
    check(pid == child.pid, "lsof names the instance we started (pid \(pid))")

    guard let info = ExternalInstance.describe(pid: pid) else {
      check(false, "ps describes pid \(pid)")
      child.kill()
      return 1
    }
    check(ExternalInstance.canStop(info), "its command line qualifies for take-over")
    check(ExternalInstance.stop(info), "SIGTERM to the group stops it")

    var freed = false
    let freeDeadline = Date().addingTimeInterval(3)
    while Date() < freeDeadline {
      if PortProbe.probe(port: port) == .free { freed = true; break }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    check(freed, "port \(port) is free, so the app may start its own")
    if exitCode == nil {
      child.kill()
    }

    if failures.isEmpty {
      print("\n✓ take-over smoke passed")
      return 0
    }
    print("\n✗ \(failures.count) take-over checks failed")
    return 1
  }

  // MARK: - Helpers

  /// `pmset -g assertions`, as text: the only place the claim "the display may
  /// sleep" can be checked from outside the app.
  private static func assertionsListing() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-g", "assertions"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
      try task.run()
    } catch {
      return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  private static func caffeinateAssertions(in listing: String, for pid: pid_t) -> [SleepAssertion] {
    SleepAssertion.caffeinateAssertions(in: listing).filter { $0.watchedPID == Int(pid) }
  }

  /// Only this run's assertions: another caffeinate on the machine is not this
  /// test's business.
  private static func caffeinateAssertions(for pid: pid_t) -> [SleepAssertion] {
    caffeinateAssertions(in: assertionsListing(), for: pid)
  }

  /// Pump the run loop while waiting: the guard publishes its status on the main
  /// queue, so a blocking sleep would never see it.
  @discardableResult
  private static func wait(seconds: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return condition()
  }

  private static func value(for flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
      return nil
    }
    return arguments[index + 1]
  }

  /// Strip the query without string surgery: the token is percent-encoded in the
  /// URL, so a naive `replacingOccurrences` would miss it whenever the token
  /// contains any character the query encoder touched.
  private static func bareRoot(of urlString: String) -> String {
    guard var components = URLComponents(string: urlString) else { return urlString }
    components.queryItems = nil
    components.fragment = nil
    return components.url?.absoluteString ?? urlString
  }

  /// A private, in-memory cookie jar, and no automatic redirects.
  ///
  /// dsh issues a *persistent* signed cookie on the token exchange; the shared jar
  /// would authenticate a later run's "bare root" request and hide the 401 fence
  /// this test exists to prove. Redirects are left unfollowed so the token
  /// request's own answer (302 + Set-Cookie) is what gets asserted, instead of a
  /// cookie-less follow-up that would read as 401.
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = HTTPCookieStorage()
    configuration.httpShouldSetCookies = true
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
  }()

  private static func fetch(_ urlString: String) -> (status: Int, body: String) {
    guard let url = URL(string: urlString) else { return (0, "") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    request.cachePolicy = .reloadIgnoringLocalCacheData

    let semaphore = DispatchSemaphore(value: 0)
    let box = ResponseBox()
    let task = session.dataTask(with: request) { data, response, error in
      box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
      box.body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      box.error = error
      semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 6)
    return (box.status, box.body)
  }

  /// Keeps the URLSession from turning dsh's 302 into a cookie-less 401.
  private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  private final class ResponseBox: @unchecked Sendable {
    var status = 0
    var body = ""
    var error: Error?
  }
}

MainActor.assumeIsolated {
  Smoke.main()
}
