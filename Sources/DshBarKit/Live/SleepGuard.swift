import Darwin
import Foundation

/// What the guard is doing right now — a fact, not a preference.
///
/// The panel only shows `awake` while this is `.asserting`: a preference that says
/// "keep the machine awake" and a caffeinate process that is actually holding the
/// assertion are two different things, and the panel must draw the second one.
public enum SleepGuardStatus: Sendable, Equatable {
  case idle
  /// A caffeinate process is watching this dsh pid.
  case asserting(pid: pid_t)
  /// There is nothing to run: the tool is not on this system.
  case unavailable(reason: String)
  /// It was started and went away on its own; `detail` says how.
  case failed(detail: String)

  public var isAsserting: Bool {
    if case .asserting = self { return true }
    return false
  }

  public var assertingPID: pid_t? {
    if case let .asserting(pid) = self { return pid }
    return nil
  }
}

/// What one reconciliation should do. Pure, so the whole decision table is
/// checkable without spawning anything.
public enum SleepGuardPlan: Sendable, Equatable {
  case noop
  /// Make sure caffeinate is running and watching this pid (swapping if needed).
  case arm(pid: pid_t)
  case release

  /// - Parameters:
  ///   - watched: the dsh pid the assertion should be tied to, or nil when no
  ///     server this app started is listening.
  ///   - lastAttemptFailed: the previous attempt at `lastAttempted` died on its
  ///     own. Retrying the same pid would only produce the same corpse, once a
  ///     second, so it waits for a different pid instead.
  public static func plan(
    policy: SleepPolicy,
    watched: pid_t?,
    status: SleepGuardStatus,
    lastAttempted: pid_t?,
    lastAttemptFailed: Bool
  ) -> SleepGuardPlan {
    guard policy.isEnabled, let pid = watched, pid > 0 else {
      return status.isAsserting ? .release : .noop
    }
    if status.assertingPID == pid { return .noop }
    // A different dsh is serving now (restart, take-over): swap, do not stack.
    if status.isAsserting { return .arm(pid: pid) }
    if lastAttemptFailed, lastAttempted == pid { return .noop }
    return .arm(pid: pid)
  }
}

/// Which dsh pid the assertion is allowed to be tied to.
///
/// One rule, in one place, because it is the whole meaning of the feature: only a
/// server this app spawned and that is actually listening counts. A server someone
/// started in a terminal belongs to that terminal; a server in `.starting` has not
/// earned the assertion yet; `.stopping` has given it up.
public enum SleepGuardTarget {
  public static func watchedPID(
    phase: HarnessPhase,
    owner: ServerOwner,
    child: pid_t?
  ) -> pid_t? {
    guard phase == .listening, owner == .dshBar, let child, child > 0 else { return nil }
    return child
  }
}

/// How an unexpected caffeinate exit is read.
///
/// `-w` makes "caffeinate died" the designed ending of every normal stop, so that
/// case goes back to `.idle` and only a caffeinate that vanishes while its dsh is
/// still running is reported as a failure. Pure, because getting this backwards is
/// how a clean stop ends up red in Settings.
public enum SleepGuardExit {
  public static func watchedAlive(pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno == EPERM
  }

  public static func status(code: Int32, watchedAlive: Bool, watched: pid_t) -> SleepGuardStatus {
    watchedAlive
      ? .failed(detail: "caffeinate exited with code \(code) while pid \(watched) is still running")
      : .idle
  }

  public static func logLine(code: Int32, watchedAlive: Bool, watched: pid_t) -> String {
    watchedAlive
      ? "sleep guard failed: caffeinate exited (\(code)), watched pid \(watched) is alive"
      : "sleep guard stopped with the dsh process (\(code)), watched pid \(watched)"
  }
}

/// Holds at most one `caffeinate -i -w <pid>` for the server the app owns.
///
/// Deliberately not built on `ChildProcess`: that type exists for one long-lived
/// dsh with line-delimited output, and giving a silent single-line tool two pipes
/// and a pair of dispatch sources buys nothing. `Process.terminationHandler` is the
/// only primitive needed here, and it answers the one question that matters — "did
/// the assertion disappear without being asked to?".
///
/// `reconcile` is idempotent and cheap when nothing changes, because the backend
/// calls it after every state dispatch, including the once-a-second uptime tick.
public final class SleepGuard {
  public var onChange: ((SleepGuardStatus) -> Void)?
  /// One line per real transition, for the log file the panel links to.
  public var onEvent: ((String) -> Void)?

  private let lock = NSLock()
  /// The caffeinate process this guard owns. Identity is the only way to tell an
  /// exit we caused from one that means the assertion is gone: `release()` and a
  /// swap both clear it *before* signalling.
  private var process: Process?
  private var lastAttempted: pid_t?
  private var lastAttemptFailed = false
  private var current: SleepGuardStatus = .idle

  public init() {}

  deinit {
    // ARC releasing the guard is a normal shutdown (app quit, backend teardown):
    // it must not leave an assertion behind.
    if let process, process.isRunning {
      process.terminate()
    }
  }

  public var status: SleepGuardStatus {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  /// Drive the guard from the two facts it is allowed to depend on.
  public func reconcile(policy: SleepPolicy, watching pid: pid_t?) {
    lock.lock()
    let plan = SleepGuardPlan.plan(
      policy: policy,
      watched: pid,
      status: current,
      lastAttempted: lastAttempted,
      lastAttemptFailed: lastAttemptFailed
    )
    lock.unlock()

    switch plan {
    case .noop:
      return
    case .release:
      release()
    case .arm(let pid):
      arm(pid)
    }
  }

  /// Stop asserting. Safe to call when idle.
  public func release() {
    lock.lock()
    let running = process
    // A stale `.failed` or `.unavailable` is also cleared here: "nothing is held
    // right now" is the only truth left once the server is gone, and leaving a
    // failure on screen after a clean stop would blame the tool for a stop the
    // user asked for.
    let previous = current
    process = nil
    lastAttempted = nil
    lastAttemptFailed = false
    lock.unlock()

    if let running, running.isRunning {
      running.terminate()
    }
    guard previous != .idle else { return }
    publish(.idle)
    emit("sleep guard released")
  }

  // MARK: - Private

  private func arm(_ pid: pid_t) {
    // Stop whatever is there first: two caffeinate processes would mean two
    // assertions, and only one of them would be released on the way out.
    stopCurrent()

    lock.lock()
    lastAttempted = pid
    lock.unlock()

    guard
      Caffeinate.isAvailable(),
      let arguments = Caffeinate.arguments(for: .whileListening, watching: pid)
    else {
      lock.lock()
      lastAttemptFailed = true
      lock.unlock()
      publish(.unavailable(reason: Caffeinate.missingReason))
      emit("sleep guard unavailable: \(Caffeinate.executable) is missing")
      return
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: Caffeinate.executable)
    task.arguments = arguments
    task.standardInput = FileHandle.nullDevice
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    // Captured identity, not a flag: whatever `process` holds when this fires
    // decides whether the exit was ours.
    task.terminationHandler = { [weak self] finished in
      self?.handleExit(finished, code: finished.terminationStatus, watched: pid)
    }

    do {
      try task.run()
    } catch {
      lock.lock()
      lastAttemptFailed = true
      lock.unlock()
      publish(.failed(detail: "\(error)"))
      emit("sleep guard failed to start: \(error)")
      return
    }

    lock.lock()
    process = task
    lastAttemptFailed = false
    lock.unlock()

    publish(.asserting(pid: pid))
    emit("sleep guard: \(Caffeinate.describe(for: .whileListening, watching: pid) ?? "") (asserting)")
  }

  private func stopCurrent() {
    lock.lock()
    let running = process
    process = nil
    lock.unlock()
    if let running, running.isRunning {
      running.terminate()
    }
  }

  /// caffeinate exits by itself the moment the watched process does — that is the
  /// whole reason `-w` is used. So an exit nobody asked for means the assertion is
  /// gone while the app still believes it should be holding one: say so instead of
  /// pretending, and do not retry the same pid (a dead pid stays dead).
  private func handleExit(_ finished: Process, code: Int32, watched: pid_t) {
    lock.lock()
    let ours = process === finished
    if ours {
      process = nil
      lastAttemptFailed = true
    }
    lock.unlock()

    guard ours else { return }
    // `-w` means caffeinate dies with its server; that is the designed ending, so it
    // goes back to idle rather than into a failure the user would have to interpret.
    // Only a caffeinate that vanishes while the dsh is still running is an anomaly.
    let alive = SleepGuardExit.watchedAlive(pid: watched)
    publish(SleepGuardExit.status(code: code, watchedAlive: alive, watched: watched))
    emit(SleepGuardExit.logLine(code: code, watchedAlive: alive, watched: watched))
  }

  private func publish(_ status: SleepGuardStatus) {
    lock.lock()
    current = status
    lock.unlock()
    let handler = onChange
    DispatchQueue.main.async {
      handler?(status)
    }
  }

  private func emit(_ line: String) {
    let handler = onEvent
    DispatchQueue.main.async {
      handler?(line)
    }
  }
}
