import Foundation

/// Whether dsh bar keeps the machine awake, and when.
///
/// The workflow this exists for is a long harness session: the panel is folded
/// away, the display has gone dark, and the machine must not idle-sleep out from
/// under the server. Keeping the screen lit is a different thing entirely — macOS
/// has one assertion for each, and holding the system one alone is exactly what
/// "turn the screen off, keep working" means.
///
/// The default is `whileListening` because that is the whole point of the feature;
/// it is bounded by the server's lifetime, visible in the panel footer, and can be
/// switched off from the right-click menu without opening Settings.
public enum SleepPolicy: String, Sendable, Equatable, CaseIterable, Identifiable {
  /// Never assert anything: the machine sleeps exactly as macOS decides.
  case off
  /// Assert only while a server this app started is listening.
  case whileListening

  public var id: String { rawValue }

  public static let `default` = SleepPolicy.whileListening

  public var isEnabled: Bool { self != .off }

  /// The integration hook, the same shape as `DSHBAR_QUIT_BEHAVIOR`: a scripted
  /// launch has no way to click a segmented control, but the behaviour behind it
  /// still has to be exercised.
  public static let environmentKey = "DSHBAR_SLEEP_POLICY"

  public static func forced(from environment: [String: String]) -> SleepPolicy? {
    environment[environmentKey].flatMap(SleepPolicy.init(rawValue:))
  }

  public static func label(_ policy: SleepPolicy, language: UILanguage) -> String {
    switch policy {
    case .off:
      return language == .zhHans ? "关闭" : "Off"
    case .whileListening:
      return language == .zhHans ? "服务运行时" : "While serving"
    }
  }
}
