import Foundation

/// The environment a terminal would give `dsh`.
///
/// `dsh` is `#!/usr/bin/env node`: the kernel resolves `node` through the child's
/// PATH, and a GUI app's PATH has no `node`. Asking the login shell is the only
/// way to get the same PATH the user's terminal has (nvm, Homebrew, miniforge).
public enum LoginShellEnvironment {
  public static let shell = "/bin/zsh"
  public static let script = "command env -0"

  public enum Source: String, Sendable, Equatable {
    case loginShell
    case process
  }

  public static let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  /// Parse `env -0`: NUL separated `KEY=value` entries, values may contain
  /// newlines and `=`; only the first `=` separates.
  public static func parse(_ data: Data) -> [String: String] {
    var values: [String: String] = [:]
    for chunk in data.split(separator: 0, omittingEmptySubsequences: true) {
      guard
        let entry = String(data: Data(chunk), encoding: .utf8),
        let separator = entry.firstIndex(of: "=")
      else { continue }
      let key = String(entry[entry.startIndex..<separator])
      guard !key.isEmpty else { continue }
      values[key] = String(entry[entry.index(after: separator)...])
    }
    return values
  }

  /// Strip the variables that would make a nested boot think it is already
  /// inside a session: the app's own controls, and the runtime's session keys.
  /// `DSH_HOME` survives, because it is configuration rather than a session id.
  public static func sanitize(
    _ environment: [String: String],
    home: String,
    fallback: [String: String] = [:]
  ) -> [String: String] {
    var values = environment
    for key in values.keys where key.hasPrefix("DSHBAR_") {
      values.removeValue(forKey: key)
    }
    for key in values.keys where key.hasPrefix("DSH_") && key != "DSH_HOME" {
      values.removeValue(forKey: key)
    }
    for key in ["PWD", "OLDPWD", "SHLVL", "_", "TTY", "SHELL_SESSION_ID"] {
      values.removeValue(forKey: key)
    }
    if (values["HOME"] ?? "").isEmpty {
      values["HOME"] = fallback["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home
    }
    if (values["PATH"] ?? "").isEmpty {
      values["PATH"] = fallback["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultPath
    }
    if (values["TMPDIR"] ?? "").isEmpty, let tmp = fallback["TMPDIR"], !tmp.isEmpty {
      values["TMPDIR"] = tmp
    }
    return values
  }

  /// Runs the login shell once (it costs about ten milliseconds) and returns what
  /// it printed, or nil when the shell is missing, hung, or produced no entries.
  public static func capture(
    timeout: TimeInterval = 3,
    shell: String = shell,
    script: String = script
  ) -> [String: String]? {
    guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-lc", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return nil
    }

    let box = DataBox()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
      box.value = pipe.fileHandleForReading.readDataToEndOfFile()
      done.signal()
    }

    if done.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      // Give the reader a moment to drain the pipe so it does not outlive us.
      _ = done.wait(timeout: .now() + 0.2)
      return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let parsed = parse(box.value)
    return parsed.isEmpty ? nil : parsed
  }

  /// `capture` with the process environment as a fallback, which already has the
  /// right HOME even when the shell cannot be reached.
  public static func resolve(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    fallback: [String: String] = ProcessInfo.processInfo.environment,
    timeout: TimeInterval = 3
  ) -> (values: [String: String], source: Source) {
    if let captured = capture(timeout: timeout) {
      return (sanitize(captured, home: home, fallback: fallback), .loginShell)
    }
    return (sanitize(fallback, home: home, fallback: fallback), .process)
  }

  private final class DataBox: @unchecked Sendable {
    var value = Data()
  }
}
