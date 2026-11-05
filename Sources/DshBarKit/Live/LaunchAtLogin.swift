import Foundation
import ServiceManagement

/// Whether dsh bar is registered to start at login.
///
/// `SMAppService` is the only supported way to do this without a helper bundle,
/// but its status is a raw enum plus a possible error, and the UI has to be honest
/// about three different "not on" states: never registered, waiting for the user
/// to approve it in System Settings, and impossible here (not a bundle, unstable
/// signature). The mapping is kept pure so it can be checked without registering
/// anything.
public enum LoginItemStatus: Sendable, Equatable {
  case enabled
  /// The user has to approve the item in System Settings → General → Login Items.
  case requiresApproval
  case notRegistered
  /// This copy of the app cannot register itself, and the reason is printable.
  case unavailable(reason: String)

  public var isOn: Bool { self == .enabled }

  /// The switch is only usable when something can actually happen.
  public var isOffered: Bool {
    switch self {
    case .enabled, .requiresApproval, .notRegistered: return true
    case .unavailable: return false
    }
  }
}

public enum LaunchAtLogin {
  /// `SMAppService.Status` raw values, named so the mapping does not depend on
  /// importing ServiceManagement at the check site.
  public enum Raw: Int, Sendable, CaseIterable {
    case notRegistered = 0
    case enabled = 1
    case requiresApproval = 2
    case notFound = 3
  }

  public static let deepLink =
    "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

  /// The two reasons the app can produce itself, named so the UI can translate them
  /// instead of printing the English constant.
  public static let unstableReason = "an ad-hoc signature changes every build; sign it first"
  public static let unbundledReason = "needs to run as a .app to register"

  /// Pure mapping. `bundleIdentifier` and `isSignedStably` decide whether the
  /// registration can stick at all: an ad-hoc signature changes its cdhash on
  /// every build, and macOS then treats each build as a different app.
  public static func map(
    raw: Int,
    bundleIdentifier: String?,
    isSignedStably: Bool,
    reasonWhenUnavailable: String?
  ) -> LoginItemStatus {
    guard bundleIdentifier?.isEmpty == false else {
      return .unavailable(reason: reasonWhenUnavailable ?? unbundledReason)
    }
    guard isSignedStably else {
      return .unavailable(reason: reasonWhenUnavailable ?? unstableReason)
    }
    switch Raw(rawValue: raw) {
    case .enabled: return .enabled
    case .requiresApproval: return .requiresApproval
    case .notRegistered, .notFound, nil: return .notRegistered
    }
  }

  /// The live status. Only called from the app; the check tool exercises `map`.
  ///
  /// The bundle check comes first: an unbundled build can never register, so there
  /// is no reason to spawn `codesign` to find that out.
  public static func status() -> LoginItemStatus {
    let bundle = Bundle.main
    guard bundle.bundlePath.hasSuffix(".app"), let identifier = bundle.bundleIdentifier else {
      return .unavailable(reason: unbundledReason)
    }
    return map(
      raw: Int(SMAppService.mainApp.status.rawValue),
      bundleIdentifier: identifier,
      isSignedStably: isSignedStably(bundleURL: bundle.bundleURL),
      reasonWhenUnavailable: nil
    )
  }

  /// Register or unregister, returning the status afterwards so the switch can
  /// show the truth instead of the click.
  @discardableResult
  public static func set(enabled: Bool) -> LoginItemStatus {
    guard status().isOffered else { return status() }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      return .unavailable(reason: "\(error.localizedDescription)")
    }
    return status()
  }

  /// Memoised: the answer cannot change while this process lives, and the check
  /// spawns `codesign`.
  private static var signatureVerdict: Bool?

  /// An ad-hoc signature (`codesign -dvvv` reports `Signature=adhoc`) is a new code
  /// identity on every build, so TCC and `SMAppService` both forget the app.
  public static func isSignedStably(bundleURL: URL) -> Bool {
    if let verdict = signatureVerdict { return verdict }
    let verdict = readSignature(bundleURL: bundleURL)
    signatureVerdict = verdict
    return verdict
  }

  private static func readSignature(bundleURL: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-dvvv", bundleURL.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return false
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    guard text.contains("Signature=adhoc") == false else { return false }
    return text.contains("Authority=") || text.contains("CodeDirectory")
  }
}
