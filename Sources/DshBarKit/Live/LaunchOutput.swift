import Foundation

/// The one line `dsh web` prints when the server is actually up, decomposed.
public struct LaunchReport: Sendable, Equatable {
  /// Exactly as printed, minus surrounding whitespace: what "Copy link" hands out.
  public var url: String
  public var host: String
  public var port: Int
  public var token: String

  public init(url: String, host: String, port: Int, token: String) {
    self.url = url
    self.host = host
    self.port = port
    self.token = token
  }
}

/// What a single line of dsh output means for the state machine.
public enum LaunchLine: Sendable, Equatable {
  case ready(LaunchReport)
  case portInUse(port: Int?)
  case startupFailed(detail: String?)
  /// Plugin noise: `DSH_MOBILE_*` warnings, MCP servers failing to start. The
  /// real dsh boots with plenty of it, so an unrecognized line is normal.
  case ignored
}

public enum LaunchOutput {
  public static let prefix = "dsh web: "
  public static let tokenQuery = "token"

  public static func classify(_ rawLine: String) -> LaunchLine {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return .ignored }
    if let report = parse(line) { return .ready(report) }
    if let port = addressInUsePort(in: line) { return .portInUse(port: port) }
    if line.contains("EADDRINUSE") { return .portInUse(port: nil) }
    if line.contains("dsh: startup failed") {
      return .startupFailed(detail: line)
    }
    return .ignored
  }

  /// Strict on purpose: `dsh web: opening the default browser; pass --no-open to
  /// disable` also starts with the prefix but carries no URL.
  public static func parse(_ line: String) -> LaunchReport? {
    guard line.hasPrefix(prefix) else { return nil }
    let text = String(line.dropFirst(prefix.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("http") else { return nil }
    guard
      let components = URLComponents(string: text),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host,
      !host.isEmpty
    else { return nil }

    let port = components.port ?? (scheme == "https" ? 443 : 80)
    let tokens = (components.queryItems ?? [])
      .filter { $0.name == tokenQuery }
      .compactMap(\.value)
      .filter { !$0.isEmpty }
    guard tokens.count == 1 else { return nil }

    return LaunchReport(url: text, host: host, port: port, token: tokens[0])
  }

  /// `listen EADDRINUSE: address already in use 127.0.0.1:3099` → 3099.
  public static func addressInUsePort(in line: String) -> Int? {
    guard line.contains("EADDRINUSE") else { return nil }
    guard
      let match = addressInUse.firstMatch(
        in: line,
        range: NSRange(line.startIndex..., in: line)
      ),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: line)
    else { return nil }
    return Int(line[range])
  }

  // `address already in use <authority>` — the authority may be `[::1]:3080` or
  // `127.0.0.1:3080`, so the greedy prefix stops at the last colon and only the
  // trailing digits are captured.
  private static let addressInUse = try! NSRegularExpression(
    pattern: #"address already in use\s+.*:(\d{1,5})\s*$"#
  )
}
