import Foundation

/// Why a configured path cannot be used, in words the panel can print.
public enum LaunchPathProblem: Sendable, Equatable {
  /// A GUI app runs with `/` as its working directory, so `dsh-lab` does not mean
  /// what it meant in the terminal that typed it.
  case relative(path: String)
  /// Something is there, but it is not a directory.
  case notDirectory(path: String)
  /// Nothing is there.
  case missing(path: String)

  /// The path as it should be shown: the user's own text for a relative path, the
  /// absolute one otherwise.
  public var path: String {
    switch self {
    case .relative(let path), .notDirectory(let path), .missing(let path): return path
    }
  }

  public var isRelative: Bool {
    if case .relative = self { return true }
    return false
  }
}

/// The two paths a launch is configured with, already resolved.
///
/// `workingDirectory == nil` means "do not send a `chdir`": dsh then uses its own
/// default workspace. `dshHome == nil` means "inherit `DSH_HOME` from the shell".
/// The two are decided separately on purpose — the working directory is where dsh
/// looks for a project, `DSH_HOME` is where it keeps its own state.
public struct LaunchTarget: Sendable, Equatable {
  /// Where the number came from, so the log line and the settings row can say it.
  public enum Origin: String, Sendable, Equatable {
    /// Nothing configured: dsh decides.
    case dshDefault
    /// The path typed in Settings.
    case preference
    /// The login shell's own `DSH_HOME`.
    case shell
    /// "Override" with a blank field: `~/.dsh`.
    case ownDefault
  }

  public var workingDirectory: String?
  public var workspaceProblem: LaunchPathProblem?
  public var workspaceOrigin: Origin
  public var dshHome: String?
  public var dshHomeProblem: LaunchPathProblem?
  public var dshHomeOrigin: Origin

  public init(
    workingDirectory: String? = nil,
    workspaceProblem: LaunchPathProblem? = nil,
    workspaceOrigin: Origin = .dshDefault,
    dshHome: String? = nil,
    dshHomeProblem: LaunchPathProblem? = nil,
    dshHomeOrigin: Origin = .shell
  ) {
    self.workingDirectory = workingDirectory
    self.workspaceProblem = workspaceProblem
    self.workspaceOrigin = workspaceOrigin
    self.dshHome = dshHome
    self.dshHomeProblem = dshHomeProblem
    self.dshHomeOrigin = dshHomeOrigin
  }

  /// Whether a launch may go ahead. A missing `DSH_HOME` is *not* a problem: dsh
  /// creates its own state directory, and the backend makes the same call, so a
  /// fresh machine is not asked to `mkdir` first.
  public var isRunnable: Bool { workspaceProblem == nil && dshHomeProblem == nil }

  /// The environment overlay a spawn applies on top of the login shell's.
  public var environmentOverlay: [String: String] {
    guard let dshHome else { return [:] }
    return ["DSH_HOME": dshHome]
  }

  public static func resolve(
    _ preferences: BarPreferences,
    fileManager: FileManager = .default
  ) -> LaunchTarget {
    var target = LaunchTarget()

    if let raw = preferences.workspacePath {
      let path = BarPreferences.collapse(raw)
      target.workspaceOrigin = .preference
      if !path.hasPrefix("/") {
        target.workspaceProblem = .relative(path: raw)
      } else if Self.isDirectory(path, fileManager: fileManager) {
        target.workingDirectory = path
      } else if fileManager.fileExists(atPath: path) {
        target.workspaceProblem = .notDirectory(path: path)
      } else {
        target.workspaceProblem = .missing(path: path)
      }
    }

    switch preferences.dshHomeMode {
    case .followShell:
      target.dshHome = nil
      target.dshHomeOrigin = .shell
    case .override:
      let raw = preferences.dshHome ?? BarPreferences.defaultDshHome
      let path = BarPreferences.collapse(raw)
      target.dshHomeOrigin = preferences.dshHome == nil ? .ownDefault : .preference
      if !path.hasPrefix("/") {
        target.dshHomeProblem = .relative(path: raw)
        target.dshHome = nil
      } else if fileManager.fileExists(atPath: path), !Self.isDirectory(path, fileManager: fileManager) {
        target.dshHomeProblem = .notDirectory(path: path)
        target.dshHome = nil
      } else {
        // Missing is fine — `LiveBackend` creates it, the same way dsh would.
        target.dshHome = path
      }
    }

    return target
  }

  private static func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
    return isDirectory.boolValue
  }

  /// `~`-abbreviated form for a one-line settings row.
  public static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }
}
