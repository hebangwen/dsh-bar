import Darwin
import Foundation

/// A `dsh web` that was started somewhere else: a terminal, a launch agent, or
/// the session the user already has open.
///
/// The app will not authenticate to it (it never saw the launch token), and it
/// must not kill the wrong process, so stopping one checks the command line first.
public enum ExternalInstance {
  public struct Info: Sendable, Equatable {
    public var pid: Int32
    public var command: String
    public var group: Int32?

    public init(pid: Int32, command: String, group: Int32? = nil) {
      self.pid = pid
      self.command = command
      self.group = group
    }
  }

  public static let lsof = "/usr/sbin/lsof"
  public static let ps = "/bin/ps"

  /// The pid of whatever is listening on the port, if lsof can name it.
  public static func listeningPID(port: Int, timeout: TimeInterval = 2) -> Int32? {
    guard (1...65535).contains(port) else { return nil }
    let output = run(
      lsof,
      ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"],
      timeout: timeout
    )
    for line in output.split(whereSeparator: \.isNewline) {
      if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
        return pid
      }
    }
    return nil
  }

  public static func describe(pid: Int32, timeout: TimeInterval = 2) -> Info? {
    guard pid > 1 else { return nil }
    let command = run(ps, ["-o", "command=", "-p", "\(pid)"], timeout: timeout)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return nil }
    let groupText = run(ps, ["-o", "pgid=", "-p", "\(pid)"], timeout: timeout)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Info(pid: pid, command: command, group: Int32(groupText))
  }

  /// Only a node process whose command line names dsh qualifies. A random
  /// server that happens to use the port is reported, never signalled.
  public static func canStop(_ info: Info) -> Bool {
    let command = info.command
    // Match the executable itself, not every path that happens to contain "dsh":
    // this decision ends in `killpg`.
    let tokens = command.split(separator: " ").map(String.init)
    let runsDsh = tokens.contains { token in
      token.hasSuffix("/dsh") || token.hasSuffix("dsh/lib/bin.js") || token.hasSuffix("/bin.js")
    }
    guard runsDsh else { return false }
    if let group = info.group, group <= 1 || group == getpgrp() { return false }
    return true
  }

  /// SIGTERM the group, wait, then SIGKILL. Returns true when the process is gone.
  @discardableResult
  public static func stop(
    _ info: Info,
    grace: TimeInterval = 3,
    fileManager: FileManager = .default
  ) -> Bool {
    guard canStop(info) else { return false }
    let target = info.group ?? info.pid
    if killpg(target, SIGTERM) != 0, errno != ESRCH {
      // Group gone but the pid may still be there; fall through to the pid.
      _ = kill(info.pid, SIGTERM)
    }
    if waitForExit(info, timeout: grace) { return true }
    killpg(target, SIGKILL)
    _ = kill(info.pid, SIGKILL)
    return waitForExit(info, timeout: 1)
  }

  /// Public view of the zombie-aware liveness check, for the handoff verifier:
  /// a record that points at a corpse must not look alive.
  public static func isAlive(_ info: Info) -> Bool {
    isRunning(info)
  }

  public static func waitForExit(_ info: Info, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !isRunning(info) { return true }
      usleep(100_000)
    }
    return !isRunning(info)
  }

  /// `kill(pid, 0)` answers "yes" for a zombie too, which would make a stopped
  /// server look unkillable; `ps` knows the difference.
  static func isRunning(_ info: Info) -> Bool {
    if kill(info.pid, 0) != 0, errno == ESRCH { return false }
    let state = run(ps, ["-o", "stat=", "-p", "\(info.pid)"], timeout: 1)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if state.isEmpty { return false }
    return !state.hasPrefix("Z")
  }

  /// Small synchronous runner: lsof and ps answer in milliseconds, and a hung
  /// one must not hang the app, so both get a timeout.
  static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String {
    guard FileManager.default.isExecutableFile(atPath: executable) else { return "" }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return ""
    }

    let done = DispatchSemaphore(value: 0)
    let box = OutputBox()
    DispatchQueue.global(qos: .userInitiated).async {
      box.value = pipe.fileHandleForReading.readDataToEndOfFile()
      done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if done.wait(timeout: .now() + 0.2) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        try? pipe.fileHandleForReading.close()
      }
      return ""
    }
    process.waitUntilExit()
    return String(data: box.value, encoding: .utf8) ?? ""
  }

  private final class OutputBox: @unchecked Sendable {
    var value = Data()
  }
}
