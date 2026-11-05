import Darwin
import Foundation

/// The environment a terminal would give `dsh`.
///
/// `dsh` is `#!/usr/bin/env node`: the kernel resolves `node` through the child's
/// PATH, and a GUI-launched app has neither `node` nor nvm on its PATH. Asking the
/// shell is the only way to get what the user's terminal has — and it has to be the
/// **interactive** login shell, because that is the only one that reads `~/.zshrc`,
/// which is where nvm, miniforge and most `export`s actually live. `zsh -lc` reads
/// `.zprofile`/`.zshenv` and quietly returns a PATH without any of them.
public enum LoginShellEnvironment {
  public static let shell = "/bin/zsh"

  /// Printed before `env -0` so prompt noise, instant-prompt escapes and banners
  /// from a `.zshrc` cannot corrupt the first variable.
  public static let marker = "__DSHBAR_ENV_BEGIN__"
  public static let script = "builtin printf \(marker); command env -0"

  public enum Source: String, Sendable, Equatable {
    /// `zsh -lic`: login + interactive, reads `~/.zshrc`. The one that works.
    case interactiveShell
    /// `zsh -lc`: login only. Kept as the second opinion, and cheap.
    case loginShell
    /// No shell answered: the app's own environment, which has almost nothing.
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

  /// Everything after the last marker: what the command printed, without whatever
  /// the shell's own rc files printed first.
  public static func slice(_ data: Data) -> Data {
    guard
      let markerData = marker.data(using: .utf8),
      let range = data.range(of: markerData, options: .backwards)
    else { return data }
    return data[range.upperBound...]
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
    // Only session state is poison here. dsh itself reads configuration such as
    // DSH_TOOLS_MODE from the environment, so a blanket `DSH_*` sweep would
    // silently drop the user's own settings.
    for key in values.keys {
      let isSessionState = key.hasPrefix("DSH_SESSION")
        || key.hasPrefix("DSH_TOKEN")
        || key.hasPrefix("DSH_LAUNCH")
        || key == "DSH_PROFILE"
        || key == "DSH_PROFILE_DIR"
        || key == "DSH_WEB_URL"
        || key == "DSH_WEB_MODE"
      if isSessionState {
        values.removeValue(forKey: key)
      }
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

  // MARK: - PATH

  /// `node` as `#!/usr/bin/env node` would find it: first executable match.
  public static func nodePath(onPath path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    for entry in path.split(separator: ":") {
      let directory = String(entry)
      guard !directory.isEmpty else { continue }
      let candidate = (directory as NSString).appendingPathComponent("node")
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  public static func hasNode(onPath path: String?) -> Bool {
    nodePath(onPath: path) != nil
  }

  /// Put `directory` at the head of a `PATH` value, without duplicating it.
  ///
  /// This is the belt to the shell's braces: `dsh` sits in
  /// `~/.nvm/versions/node/<version>/bin` next to the exact `node` it was installed
  /// with, so that directory must win over whatever nvm's default alias points at.
  public static func prependDirectory(_ directory: String, toPath path: String?) -> String {
    var cleaned = directory
    while cleaned.count > 1, cleaned.hasSuffix("/") {
      cleaned.removeLast()
    }
    var entries = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty && $0 != cleaned }
    if !cleaned.isEmpty {
      entries.insert(cleaned, at: 0)
    }
    return entries.isEmpty ? defaultPath : entries.joined(separator: ":")
  }

  /// The PATH a `dsh` at `executable` has to run with: its own directory first —
  /// that is where the `node` it was installed alongside lives — then the shell's.
  public static func runnablePath(forExecutable executable: String, environment: [String: String]) -> String {
    let directory = (executable as NSString).deletingLastPathComponent
    return prependDirectory(directory, toPath: environment["PATH"])
  }

  // MARK: - Capture

  /// Runs the shell once and returns what it printed, or nil when the shell is
  /// missing, hung, or produced no entries.
  public static func capture(
    timeout: TimeInterval = 2.5,
    shell: String = shell,
    flags: [String] = ["-lic"],
    script: String = script
  ) -> [String: String]? {
    guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = flags + [script]
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
      if done.wait(timeout: .now() + 0.2) == .timedOut {
        // A rc file that backgrounds something holding our stdout keeps the pipe
        // open forever. Kill the shell and close our end so the reader returns.
        kill(process.processIdentifier, SIGKILL)
        try? pipe.fileHandleForReading.close()
      }
      return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let parsed = parse(slice(box.value))
    return parsed.isEmpty ? nil : parsed
  }

  /// The interactive login shell first, the login shell second, the process
  /// environment last — and, among the two shells, whichever one actually has a
  /// `node` on its PATH.
  public static func resolve(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    fallback: [String: String] = ProcessInfo.processInfo.environment,
    timeout: TimeInterval = 2.5,
    loginTimeout: TimeInterval = 1.0
  ) -> (values: [String: String], source: Source) {
    let interactive = capture(timeout: timeout, flags: ["-lic"])
    if let interactive, hasNode(onPath: interactive["PATH"]) {
      return (sanitize(interactive, home: home, fallback: fallback), .interactiveShell)
    }
    let login = capture(timeout: loginTimeout, flags: ["-lc"])
    if let login, hasNode(onPath: login["PATH"]) {
      return (sanitize(login, home: home, fallback: fallback), .loginShell)
    }
    // Neither reaches node, but the interactive one still carries the user's own
    // exports (proxies, DSH_*), which is more useful than nothing.
    if let interactive {
      return (sanitize(interactive, home: home, fallback: fallback), .interactiveShell)
    }
    if let login {
      return (sanitize(login, home: home, fallback: fallback), .loginShell)
    }
    return (sanitize(fallback, home: home, fallback: fallback), .process)
  }

  private final class DataBox: @unchecked Sendable {
    var value = Data()
  }
}
