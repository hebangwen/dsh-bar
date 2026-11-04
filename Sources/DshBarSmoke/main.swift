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

    if arguments.contains("--external") {
      exit(takeOver(environment: environment.values, detection: detection, port: requested))
    }

    let before = PortProbe.probe(port: requested)
    guard before == .free else {
      print("✗ port \(requested) is not free (\(before)); stop it or pick another port")
      exit(1)
    }
    print("✓ port \(requested) is free")

    var report: LaunchReport?
    var exitCode: Int32?
    var failureDetail: String?

    let child: ChildProcess
    do {
      child = try ChildProcess(
        executable: detection.path,
        arguments: ["--profile", preferences.profile, "--no-open", "--port", "\(requested)"],
        environment: environment.values
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

    child.terminate()
    let stopDeadline = Date().addingTimeInterval(5)
    while exitCode == nil, Date() < stopDeadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check(exitCode != nil, "the server exited after SIGTERM")
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

    if failures.isEmpty {
      print("\n✓ smoke passed")
      exit(0)
    }
    print("\n✗ \(failures.count) smoke checks failed")
    exit(1)
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
