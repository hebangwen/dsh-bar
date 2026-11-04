import Foundation

/// What the app remembers between launches: only the three values process
/// control actually needs.
///
/// Kept as a plain value so the settings window, the controller, and the smoke
/// tool all agree on validation without sharing a mutable singleton.
public struct BarPreferences: Sendable, Equatable {
  public var binaryPath: String?
  public var port: Int
  public var profile: String

  public enum Key {
    public static let binaryPath = "dshBinaryPath"
    public static let port = "dshPort"
    public static let profile = "dshProfile"
  }

  public static let defaultPort = 3080
  public static let defaultProfile = "web"
  /// Let the OS pick the port; the real one is read back from the launch URL.
  public static let autoPort = 0

  public init(
    binaryPath: String? = nil,
    port: Int = BarPreferences.defaultPort,
    profile: String = BarPreferences.defaultProfile
  ) {
    self.binaryPath = Self.normalizeBinaryPath(binaryPath)
    self.port = Self.normalizePort(port)
    self.profile = Self.normalizeProfile(profile)
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

  public var isAutoPort: Bool { port == Self.autoPort }

  public static func load(from defaults: UserDefaults = .standard) -> BarPreferences {
    let port = defaults.object(forKey: Key.port) as? Int ?? defaultPort
    return BarPreferences(
      binaryPath: defaults.string(forKey: Key.binaryPath),
      port: port,
      profile: defaults.string(forKey: Key.profile) ?? defaultProfile
    )
  }

  public func save(to defaults: UserDefaults = .standard) {
    defaults.set(port, forKey: Key.port)
    defaults.set(profile, forKey: Key.profile)
    if let binaryPath {
      defaults.set(binaryPath, forKey: Key.binaryPath)
    } else {
      defaults.removeObject(forKey: Key.binaryPath)
    }
  }
}
