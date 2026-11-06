import Foundation

/// How `DSH_HOME` is decided for the child.
public enum DshHomeMode: String, Sendable, Equatable, CaseIterable {
  /// Inherit what the interactive login shell exports. The user's terminal is the
  /// one place that already says where dsh keeps its state, so nothing is duplicated
  /// and a shell change is picked up on the next start.
  case followShell
  /// Use the path in Settings; a blank path there means `~/.dsh`.
  case override
}

/// What the app remembers between launches: the values process control needs.
///
/// Kept as a plain value so the settings window, the controller, and the smoke
/// tool all agree on validation without sharing a mutable singleton.
public struct BarPreferences: Sendable, Equatable {
  public var binaryPath: String?
  public var port: Int
  public var profile: String
  /// The directory `dsh` is started in. Nil means "nothing configured": dsh picks
  /// its own workspace, and a `chdir` is not sent at all. That is deliberately not
  /// the same as "empty path" — a GUI app's working directory is `/`, so sending
  /// one that does not exist would fail inside `posix_spawn` with a misleading
  /// error instead of an explanation.
  public var workspacePath: String?
  public var dshHomeMode: DshHomeMode
  /// Only read in `.override`. Nil means `~/.dsh`.
  public var dshHome: String?
  /// What quitting the app does to a server this app started.
  public var quitBehavior: QuitBehavior
  /// The global chord that shows the panel.
  public var hotKey: HotKeyChoice
  /// Whether the machine is kept awake while a server this app started is serving.
  public var sleepPolicy: SleepPolicy
  /// `dsh --host`: nil means "do not send the flag" (dsh's own default, loopback).
  public var launchHost: String?
  /// `dsh --public-url`: what the printed and opened URL should say instead of the
  /// bind address. A reverse proxy's address, typically.
  public var publicURL: String?
  /// `dsh --trusted-host`, repeatable.
  public var trustedHosts: [String]
  /// `dsh --tls-cert` / `--tls-key`. Both or neither.
  public var tlsCertPath: String?
  public var tlsKeyPath: String?
  /// `dsh --patch`, repeatable: extra overlay files applied after the profile layer.
  public var patchPaths: [String]
  /// Restart a server that dies while serving. Bounded by `CrashWatchdog`; a
  /// manual Start resets the budget.
  public var autoRestart: Bool
  /// Post a system notification on a start failure, a crash, a give-up or a failed
  /// stop. Off means the panel is the only place that reports.
  public var notify: Bool

  public enum Key {
    public static let binaryPath = "dshBinaryPath"
    public static let port = "dshPort"
    public static let profile = "dshProfile"
    public static let workspacePath = "dshWorkspacePath"
    public static let dshHomeMode = "dshHomeMode"
    public static let dshHome = "dshHome"
    public static let quitBehavior = "dshQuitBehavior"
    public static let hotKey = "dshHotKey"
    public static let sleepPolicy = "dshSleepPolicy"
    public static let launchHost = "dshLaunchHost"
    public static let publicURL = "dshPublicURL"
    public static let trustedHosts = "dshTrustedHosts"
    public static let tlsCertPath = "dshTLSCertPath"
    public static let tlsKeyPath = "dshTLSKeyPath"
    public static let patchPaths = "dshPatchPaths"
    public static let autoRestart = "dshAutoRestart"
    public static let notify = "dshNotify"
  }

  public static let defaultPort = 3080
  public static let defaultProfile = "web"
  /// Let the OS pick the port; the real one is read back from the launch URL.
  public static let autoPort = 0
  /// `DSH_HOME` when the user turns on "override" but leaves the field blank.
  public static let defaultDshHome = "~/.dsh"

  public init(
    binaryPath: String? = nil,
    port: Int = defaultPort,
    profile: String = defaultProfile,
    workspacePath: String? = nil,
    dshHomeMode: DshHomeMode = .followShell,
    dshHome: String? = nil,
    quitBehavior: QuitBehavior = .stopManaged,
    hotKey: HotKeyChoice = .default,
    sleepPolicy: SleepPolicy = .default,
    launchHost: String? = nil,
    publicURL: String? = nil,
    trustedHosts: [String] = [],
    tlsCertPath: String? = nil,
    tlsKeyPath: String? = nil,
    patchPaths: [String] = [],
    autoRestart: Bool = true,
    notify: Bool = true
  ) {
    self.binaryPath = Self.normalizeBinaryPath(binaryPath)
    self.port = Self.normalizePort(port)
    self.profile = Self.normalizeProfile(profile)
    self.workspacePath = Self.normalizeWorkspacePath(workspacePath)
    self.dshHomeMode = dshHomeMode
    self.dshHome = Self.normalizeDshHome(dshHome)
    self.quitBehavior = quitBehavior
    self.hotKey = hotKey
    self.sleepPolicy = sleepPolicy
    self.launchHost = Self.normalizeHost(launchHost)
    self.publicURL = Self.normalizeURL(publicURL)
    self.trustedHosts = Self.normalizeTrustedHosts(trustedHosts)
    self.tlsCertPath = Self.normalizeFilePath(tlsCertPath)
    self.tlsKeyPath = Self.normalizeFilePath(tlsKeyPath)
    self.patchPaths = Self.normalizePaths(patchPaths)
    self.autoRestart = autoRestart
    self.notify = notify
  }

  /// 0 means "auto"; anything outside 1...65535 falls back to the default.
  public static func normalizePort(_ raw: Int) -> Int {
    if raw == Self.autoPort { return raw }
    return (1...65535).contains(raw) ? raw : defaultPort
  }

  public static func normalizeProfile(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? defaultProfile : trimmed
  }

  public static func normalizeBinaryPath(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// `~` is expanded here, once, so every consumer sees an absolute path. A
  /// relative path is kept as it was typed — rejecting it with an explanation is
  /// `LaunchTarget`'s job, and it needs the original text to quote it.
  public static func normalizeWorkspacePath(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return Self.collapse(trimmed)
  }

  public static func normalizeDshHome(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return Self.collapse(trimmed)
  }

  /// Expand `~` and collapse `..` / `//` without touching the filesystem: a path
  /// that does not exist yet still has to be comparable and displayable.
  public static func collapse(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { return expanded }
    return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
  }

  /// `--host`: trimmed, and an empty field means "no flag", not "bind nowhere".
  public static func normalizeHost(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  public static func normalizeURL(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// One text field in Settings holds all of them, separated by commas or spaces;
  /// duplicates would only make dsh repeat itself.
  public static func normalizeTrustedHosts(_ raw: [String]) -> [String] {
    var seen = Set<String>()
    var values: [String] = []
    for piece in raw.flatMap({ $0.split(whereSeparator: { $0 == "," || $0.isWhitespace }) }) {
      let value = piece.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, seen.insert(value).inserted else { continue }
      values.append(value)
    }
    return values
  }

  public static func normalizeFilePath(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return Self.collapse(trimmed)
  }

  public static func normalizePaths(_ raw: [String]) -> [String] {
    var seen = Set<String>()
    var values: [String] = []
    for piece in raw {
      guard let path = Self.normalizeFilePath(piece), seen.insert(path).inserted else { continue }
      values.append(path)
    }
    return values
  }

  /// The flags a launch would send, derived from the stored fields. The spawn path
  /// and the settings validation both read this, so they cannot disagree.
  public var launchFlags: WebLaunchFlags {
    WebLaunchFlags(
      host: launchHost,
      publicURL: publicURL,
      trustedHosts: trustedHosts,
      tlsCertPath: tlsCertPath,
      tlsKeyPath: tlsKeyPath,
      patches: patchPaths
    )
  }

  public mutating func setLaunchFlags(_ flags: WebLaunchFlags) {
    launchHost = flags.host
    publicURL = flags.publicURL
    trustedHosts = flags.trustedHosts
    tlsCertPath = flags.tlsCertPath
    tlsKeyPath = flags.tlsKeyPath
    patchPaths = flags.patches
  }

  public var trustedHostsText: String { trustedHosts.joined(separator: ", ") }

  public var isAutoPort: Bool { port == Self.autoPort }

  /// A copy with only the port changed.
  ///
  /// Callers that learn the port late (an OS-assigned port, a take-over on another
  /// port) must not rebuild the whole struct: every field they forget is data loss,
  /// and 0.4.0 added five of them.
  public func replacing(port: Int) -> BarPreferences {
    var next = self
    next.port = Self.normalizePort(port)
    return next
  }

  public static func load(from defaults: UserDefaults = .standard) -> BarPreferences {
    let port = defaults.object(forKey: Key.port) as? Int ?? defaultPort
    // Anything written by 0.3.0 has no keys for the M3 fields; the defaults below
    // are exactly the old behaviour, so an upgrade changes nothing until the user
    // asks for something else.
    let mode = defaults.string(forKey: Key.dshHomeMode).flatMap(DshHomeMode.init(rawValue:)) ?? .followShell
    let quit = defaults.string(forKey: Key.quitBehavior).flatMap(QuitBehavior.init(rawValue:)) ?? .stopManaged
    let hotKey = defaults.string(forKey: Key.hotKey).flatMap(HotKeyChoice.init(rawValue:)) ?? .default
    // The one place 0.4.0's "an upgrade changes nothing" rule is deliberately
    // broken: keeping the machine awake while the server runs is the 0.5.0
    // feature, it is bounded by the server's lifetime, it is visible in the panel
    // footer, and the right-click menu turns it off in two clicks.
    let sleep = defaults.string(forKey: Key.sleepPolicy)
      .flatMap(SleepPolicy.init(rawValue:)) ?? .default
    return BarPreferences(
      binaryPath: defaults.string(forKey: Key.binaryPath),
      port: port,
      profile: defaults.string(forKey: Key.profile) ?? defaultProfile,
      workspacePath: defaults.string(forKey: Key.workspacePath),
      dshHomeMode: mode,
      dshHome: defaults.string(forKey: Key.dshHome),
      quitBehavior: quit,
      hotKey: hotKey,
      sleepPolicy: sleep,
      launchHost: defaults.string(forKey: Key.launchHost),
      publicURL: defaults.string(forKey: Key.publicURL),
      trustedHosts: defaults.stringArray(forKey: Key.trustedHosts) ?? [],
      tlsCertPath: defaults.string(forKey: Key.tlsCertPath),
      tlsKeyPath: defaults.string(forKey: Key.tlsKeyPath),
      patchPaths: defaults.stringArray(forKey: Key.patchPaths) ?? [],
      // 0.6.0 domains have neither key; both defaults are the new behaviour, and
      // both are visible and switchable in Settings › Behavior.
      autoRestart: defaults.object(forKey: Key.autoRestart) as? Bool ?? true,
      notify: defaults.object(forKey: Key.notify) as? Bool ?? true
    )
  }

  public func save(to defaults: UserDefaults = .standard) {
    defaults.set(port, forKey: Key.port)
    defaults.set(profile, forKey: Key.profile)
    defaults.set(dshHomeMode.rawValue, forKey: Key.dshHomeMode)
    defaults.set(quitBehavior.rawValue, forKey: Key.quitBehavior)
    defaults.set(hotKey.rawValue, forKey: Key.hotKey)
    defaults.set(sleepPolicy.rawValue, forKey: Key.sleepPolicy)
    Self.store(binaryPath, key: Key.binaryPath, in: defaults)
    Self.store(workspacePath, key: Key.workspacePath, in: defaults)
    Self.store(dshHome, key: Key.dshHome, in: defaults)
    Self.store(launchHost, key: Key.launchHost, in: defaults)
    Self.store(publicURL, key: Key.publicURL, in: defaults)
    Self.store(tlsCertPath, key: Key.tlsCertPath, in: defaults)
    Self.store(tlsKeyPath, key: Key.tlsKeyPath, in: defaults)
    Self.store(trustedHosts, key: Key.trustedHosts, in: defaults)
    Self.store(patchPaths, key: Key.patchPaths, in: defaults)
    // `set(_:forKey:)` picks the type from the static one; assigning a `Bool?`
    // after promotion would store an integer, which `as? Bool` never reads back.
    defaults.set(autoRestart, forKey: Key.autoRestart)
    defaults.set(notify, forKey: Key.notify)
  }

  private static func store(_ values: [String], key: String, in defaults: UserDefaults) {
    if values.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(values, forKey: key)
    }
  }

  private static func store(_ value: String?, key: String, in defaults: UserDefaults) {
    if let value {
      defaults.set(value, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}
