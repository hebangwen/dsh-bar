import Foundation

/// A `dsh` the app may run, and where that answer came from.
public struct DshDetection: Sendable, Equatable {
  public enum Source: String, Sendable, Equatable, CaseIterable {
    /// Picked by hand in Settings.
    case setting
    /// `DSHBAR_DSH_PATH`, used by the smoke tool and by tests.
    case environment
    /// Somewhere on the PATH the login shell reports.
    case path
    /// `~/.nvm/versions/node/<version>/bin/dsh`.
    case nvm
    case homebrew
    case localBin
  }

  public var path: String
  public var source: Source

  public init(path: String, source: Source) {
    self.path = path
    self.source = source
  }
}

public enum DshLookup: Sendable, Equatable {
  case found(DshDetection)
  /// Everything that was tried, in order, so the panel can explain itself.
  case missing(searched: [String])
}

/// Finds the `dsh` executable without trusting the process environment.
///
/// A GUI app started from Finder inherits `/usr/bin:/bin:/usr/sbin:/sbin`, which
/// has no `node`; `dsh` is a `#!/usr/bin/env node` script, so running it from
/// that environment fails with `env: node: No such file or directory`. The fix is
/// to ask the user's **interactive** login shell for its environment (see
/// `LoginShellEnvironment`) and to put dsh's own directory at the head of PATH.
public enum DshLocator {
  public struct Candidate: Sendable, Equatable {
    public var path: String
    public var source: DshDetection.Source

    public init(path: String, source: DshDetection.Source) {
      self.path = path
      self.source = source
    }
  }

  public static let environmentKey = "DSHBAR_DSH_PATH"

  /// Ordering only: no file system, no environment lookup, so it can be asserted.
  public static func candidates(
    explicit: String?,
    pathEnv: String?,
    home: String,
    nvmVersions: [String] = [],
    environmentOverride: String? = nil
  ) -> [Candidate] {
    var found: [Candidate] = []

    func add(_ path: String?, _ source: DshDetection.Source) {
      guard let path, !path.isEmpty else { return }
      guard !found.contains(where: { $0.path == path }) else { return }
      found.append(Candidate(path: path, source: source))
    }

    add(BarPreferences.normalizeBinaryPath(explicit), .setting)
    add(BarPreferences.normalizeBinaryPath(environmentOverride), .environment)

    for directory in (pathEnv ?? "").split(separator: ":") {
      let text = String(directory)
      guard !text.isEmpty else { continue }
      add("\(text)/dsh", .path)
    }

    for version in sortVersions(nvmVersions) {
      add("\(home)/.nvm/versions/node/\(version)/bin/dsh", .nvm)
    }

    add("/opt/homebrew/bin/dsh", .homebrew)
    add("/usr/local/bin/dsh", .localBin)
    return found
  }

  /// Newest runtime first: `24.22.2` outranks `18.9.0`, which a plain string
  /// sort would get backwards.
  public static func sortVersions(_ versions: [String]) -> [String] {
    versions.sorted { compareVersions($0, $1) > 0 }
  }

  static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
    let left = lhs.split(separator: ".").map(String.init)
    let right = rhs.split(separator: ".").map(String.init)
    for index in 0..<max(left.count, right.count) {
      let a = index < left.count ? left[index] : "0"
      let b = index < right.count ? right[index] : "0"
      if let x = Int(a), let y = Int(b) {
        if x != y { return x < y ? -1 : 1 }
      } else if a != b {
        return a < b ? -1 : 1
      }
    }
    return 0
  }

  /// Why `node` has to be on the PATH at all: dsh is installed as a script whose
  /// interpreter is resolved by `env`. Reading the first line is what lets the app
  /// report "node is missing" instead of "dsh exited (code 127)".
  public static func isEnvNodeScript(at path: String) -> Bool {
    guard let handle = FileHandle(forReadingAtPath: path) else { return false }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: 200)
    guard
      let text = String(data: data, encoding: .utf8),
      text.hasPrefix("#!")
    else { return false }
    let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      .first
      .map(String.init) ?? text
    return firstLine.contains("env") && firstLine.contains("node")
  }

  public static func isExecutable(_ path: String, fileManager: FileManager = .default) -> Bool {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      return false
    }
    return fileManager.isExecutableFile(atPath: path)
  }

  /// The nvm runtime directories, newest first. Empty when the user has no nvm.
  public static func nvmVersions(home: String, fileManager: FileManager = .default) -> [String] {
    let root = "\(home)/.nvm/versions/node"
    let names = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
    return sortVersions(names.filter { !$0.hasPrefix(".") })
  }

  /// Full lookup: builds the candidate list, then keeps the first executable one.
  public static func resolve(
    explicit: String?,
    pathEnv: String?,
    home: String,
    environmentOverride: String? = nil,
    fileManager: FileManager = .default
  ) -> DshLookup {
    let versions = nvmVersions(home: home, fileManager: fileManager)
    let candidates = candidates(
      explicit: explicit,
      pathEnv: pathEnv,
      home: home,
      nvmVersions: versions,
      environmentOverride: environmentOverride
    )
    for candidate in candidates where isExecutable(candidate.path, fileManager: fileManager) {
      return .found(DshDetection(path: candidate.path, source: candidate.source))
    }
    return .missing(searched: candidates.map(\.path))
  }
}
