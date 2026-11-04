import SwiftUI

// MARK: - Palette

/// The panel inherits DSH's own tokens: near-black ink on paper, 10% rules,
/// a monochrome brand. The only hues in the app are the two meanings a running
/// service actually has — "changing" and "broken".
public struct Palette {
  public var plate: Color
  public var well: Color
  public var ink: Color
  public var inkSecondary: Color
  public var inkTertiary: Color
  public var rule: Color
  public var ruleGlow: Color
  public var warn: Color
  public var fail: Color

  public init(
    plate: Color,
    well: Color,
    ink: Color,
    inkSecondary: Color,
    inkTertiary: Color,
    rule: Color,
    ruleGlow: Color,
    warn: Color,
    fail: Color
  ) {
    self.plate = plate
    self.well = well
    self.ink = ink
    self.inkSecondary = inkSecondary
    self.inkTertiary = inkTertiary
    self.rule = rule
    self.ruleGlow = ruleGlow
    self.warn = warn
    self.fail = fail
  }

  public static let light = Palette(
    plate: Color(hex: 0xFBFBFA),
    well: Color(hex: 0xEFEFEC),
    ink: Color(hex: 0x0F1115),
    inkSecondary: Color(hex: 0x61666B),
    inkTertiary: Color(hex: 0x6F7378),
    rule: Color(hex: 0x0F1115).opacity(0.16),
    ruleGlow: Color.white.opacity(0.85),
    warn: Color(hex: 0xA8641A),
    fail: Color(hex: 0xB02A1E)
  )

  public static let dark = Palette(
    plate: Color(hex: 0x16181B),
    well: Color(hex: 0x0A0C0E),
    ink: Color(hex: 0xF2F3F4),
    inkSecondary: Color(hex: 0xB9BEC4),
    inkTertiary: Color(hex: 0x8F959B),
    rule: Color.white.opacity(0.16),
    ruleGlow: Color.white.opacity(0.06),
    warn: Color(hex: 0xE0A44A),
    fail: Color(hex: 0xF2705F)
  )

  public static func forScheme(_ scheme: ColorScheme) -> Palette {
    scheme == .dark ? .dark : .light
  }
}

// MARK: - Type

/// One family per job, all system-provided so nothing silently substitutes:
/// the monospaced face is the instrument (state word, readout, log), the UI face
/// is prose and actions. Setting the *hero* in monospace is the deliberate
/// inversion — the panel reads like a printout, which is what it is.
public enum Typography {
  public static func hero(_ language: UILanguage) -> Font {
    .system(size: language.isCJK ? 24 : 30, weight: .medium, design: .monospaced)
  }

  public static func heroTracking(_ language: UILanguage) -> CGFloat {
    language.isCJK ? 0.5 : -0.3
  }

  public static let wordmark = Font.system(size: 12, weight: .medium, design: .monospaced)
  public static let readout = Font.system(size: 12, weight: .regular, design: .monospaced)
  public static let meta = Font.system(size: 10.5, weight: .regular, design: .monospaced)
  public static let log = Font.system(size: 10, weight: .regular, design: .monospaced)
  public static let body = Font.system(size: 11.5, weight: .regular)
  public static let heading = Font.system(size: 12.5, weight: .semibold)
  public static let button = Font.system(size: 12, weight: .medium)
  public static let label = Font.system(size: 10.5, weight: .medium)
}

// MARK: - Metrics

public enum Metrics {
  public static let panelWidth: CGFloat = 348
  public static let pad: CGFloat = 18
  public static let panelRadius: CGFloat = 18

  public static let mastheadTop: CGFloat = 13
  public static let mastheadHeight: CGFloat = 30

  public static let heroTop: CGFloat = 7
  public static let bandTop: CGFloat = 12
  public static let bandPadVertical: CGFloat = 7

  public static let actionTop: CGFloat = 12
  public static let actionHeight: CGFloat = 36
  public static let actionRadius: CGFloat = 10
  public static let actionGap: CGFloat = 8
  public static let tertiaryHeight: CGFloat = 24

  public static let detailTop: CGFloat = 12
  public static let logLineHeight: CGFloat = 15

  public static let footerHeight: CGFloat = 28
  public static let footerBottomPad: CGFloat = 3
}

// MARK: - Color helpers

public extension Color {
  /// `Color(hex: 0xFBFBFA)` — sRGB, no alpha channel in the literal.
  init(hex: UInt32, alpha: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: alpha
    )
  }
}
