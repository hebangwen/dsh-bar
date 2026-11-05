import Carbon.HIToolbox
import Foundation

/// One global shortcut, expressed as data.
///
/// `⌥⌘D` and `⌃⌥D` are the two shapes worth offering: both avoid the system's own
/// command-key space, and neither needs Accessibility permission — Carbon's
/// `RegisterEventHotKey` runs from any app, which is exactly why it is still the
/// right API for this. The virtual key codes are macOS constants and the modifiers
/// are Carbon masks, kept here so the check tool can assert the pair without
/// touching the event system.
public enum HotKeyChoice: String, Sendable, Equatable, CaseIterable, Identifiable {
  case optionCommandD
  case controlOptionD
  case off

  public var id: String { rawValue }

  public static let `default` = HotKeyChoice.optionCommandD

  /// Virtual key code for `D` (`kVK_ANSI_D`).
  public static let keyCodeD: UInt32 = 2

  public var keyCode: UInt32? {
    switch self {
    case .off: return nil
    case .optionCommandD, .controlOptionD: return Self.keyCodeD
    }
  }

  /// Carbon masks: `cmdKey` 256, `optionKey` 2048, `controlKey` 4096.
  public var modifiers: UInt32 {
    switch self {
    case .off: return 0
    case .optionCommandD: return UInt32(cmdKey | optionKey)
    case .controlOptionD: return UInt32(controlKey | optionKey)
    }
  }

  public var isEnabled: Bool { self != .off }

  public var label: String {
    switch self {
    case .optionCommandD: return "⌥⌘D"
    case .controlOptionD: return "⌃⌥D"
    case .off: return "—"
    }
  }

  /// What the settings row prints next to the choice.
  public func label(language: UILanguage) -> String {
    guard isEnabled else { return language == .zhHans ? "关闭" : "Off" }
    return label
  }
}

/// The registration state, so the settings row can be honest about a shortcut that
/// could not be installed instead of showing a promise.
public enum HotKeyStatus: Sendable, Equatable {
  case off
  case active
  /// Another app (or the system) already owns the combination.
  case taken

  public var isActive: Bool { self == .active }
}
