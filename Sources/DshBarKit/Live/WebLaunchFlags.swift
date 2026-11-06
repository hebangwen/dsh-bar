import Darwin
import Foundation

/// The `dsh web` flags dsh bar is willing to put on the command line, as one value.
///
/// `dsh web --help` offers eight; the app used to pass two (`--profile`, `--port`).
/// Everything here is optional and defaults to "say nothing", so a 0.5.0 install
/// keeps launching exactly the argv it launched before.
///
/// Validation is a pure function with an injected file check, because the two
/// interesting questions — "is this a bindable literal?" and "is that certificate
/// still there?" — have to be answerable without spawning anything.
public struct WebLaunchFlags: Sendable, Equatable {
  /// Which row a problem belongs to, so Settings can put the red text next to the
  /// field that caused it.
  public enum Field: String, Sendable, Equatable, CaseIterable {
    case host
    case publicURL
    case trustedHost
    case tlsCert
    case tlsKey
    case patch
  }

  public enum Problem: Sendable, Equatable {
    /// `0.0.0.0` / `::` / `*`: dsh refuses wildcard binds, and so does this.
    case wildcardHost(String)
    /// Not a concrete IPv4 or IPv6 literal — a host name is not an address.
    case invalidHost(String)
    case invalidPublicURL(String)
    case invalidTrustedHost(String)
    /// `--tls-cert` without `--tls-key` (or the other way round) is a dsh error
    /// waiting to happen; the app says it before spawning.
    case tlsNeedsBoth
    case missingFile(field: Field, path: String)
    case emptyPatch

    public var field: Field {
      switch self {
      case .wildcardHost, .invalidHost: return .host
      case .invalidPublicURL: return .publicURL
      case .invalidTrustedHost: return .trustedHost
      case .tlsNeedsBoth: return .tlsCert
      case let .missingFile(field, _): return field
      case .emptyPatch: return .patch
      }
    }
  }

  /// Nil means "do not send `--host`": dsh binds its own default (loopback).
  public var host: String?
  public var publicURL: String?
  public var trustedHosts: [String]
  public var tlsCertPath: String?
  public var tlsKeyPath: String?
  public var patches: [String]

  public init(
    host: String? = nil,
    publicURL: String? = nil,
    trustedHosts: [String] = [],
    tlsCertPath: String? = nil,
    tlsKeyPath: String? = nil,
    patches: [String] = []
  ) {
    self.host = host
    self.publicURL = publicURL
    self.trustedHosts = trustedHosts
    self.tlsCertPath = tlsCertPath
    self.tlsKeyPath = tlsKeyPath
    self.patches = patches
  }

  public static let empty = WebLaunchFlags()

  /// True when the app would pass exactly the 0.5.0 argv.
  public var isDefault: Bool {
    host == nil
      && publicURL == nil
      && trustedHosts.isEmpty
      && tlsCertPath == nil
      && tlsKeyPath == nil
      && patches.isEmpty
  }

  public var usesTLS: Bool { tlsCertPath != nil && tlsKeyPath != nil }

  /// A bind address that other machines on the network can reach. The panel shows a
  /// badge for it: "serving on the LAN" is worth saying out loud.
  public var bindsBeyondLoopback: Bool {
    guard let host else { return false }
    return !Self.isLoopback(host)
  }

  /// The whole argv, in one place, so `dshbar-check` can assert the exact array.
  public func arguments(profile: String, port: Int, noOpen: Bool = true) -> [String] {
    var arguments = ["--profile", profile]
    if noOpen { arguments.append("--no-open") }
    if port != BarPreferences.autoPort {
      arguments.append(contentsOf: ["--port", "\(port)"])
    }
    if let host {
      arguments.append(contentsOf: ["--host", host])
    }
    if let publicURL {
      arguments.append(contentsOf: ["--public-url", publicURL])
    }
    for trusted in trustedHosts {
      arguments.append(contentsOf: ["--trusted-host", trusted])
    }
    if let tlsCertPath {
      arguments.append(contentsOf: ["--tls-cert", tlsCertPath])
    }
    if let tlsKeyPath {
      arguments.append(contentsOf: ["--tls-key", tlsKeyPath])
    }
    for patch in patches {
      arguments.append(contentsOf: ["--patch", patch])
    }
    return arguments
  }

  /// Everything wrong with these flags, in the order Settings shows them.
  ///
  /// - Parameter fileExists: injected so the decision table is assertable; the
  ///   real call passes `FileManager`.
  public func problems(
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> [Problem] {
    var problems: [Problem] = []
    if let host, let problem = Self.hostProblem(host) {
      problems.append(problem)
    }
    if let publicURL, !Self.isPublicURL(publicURL) {
      problems.append(.invalidPublicURL(publicURL))
    }
    for trusted in trustedHosts where !Self.isTrustedHost(trusted) {
      problems.append(.invalidTrustedHost(trusted))
    }
    if (tlsCertPath == nil) != (tlsKeyPath == nil) {
      problems.append(.tlsNeedsBoth)
    }
    if let tlsCertPath, !fileExists(tlsCertPath) {
      problems.append(.missingFile(field: .tlsCert, path: tlsCertPath))
    }
    if let tlsKeyPath, !fileExists(tlsKeyPath) {
      problems.append(.missingFile(field: .tlsKey, path: tlsKeyPath))
    }
    for patch in patches {
      if patch.isEmpty {
        problems.append(.emptyPatch)
      } else if !fileExists(patch) {
        problems.append(.missingFile(field: .patch, path: patch))
      }
    }
    return problems
  }

  /// The first problem, which is the one a failed launch reports.
  public func firstProblem(
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> Problem? {
    problems(fileExists: fileExists).first
  }

  // MARK: - Address rules

  /// `dsh --host` takes one concrete IPv4 or IPv6 literal of a local interface and
  /// rejects wildcard addresses. A host name is not an address, so it is refused
  /// here rather than by a spawn that fails 30 seconds later.
  public static func hostProblem(_ raw: String) -> Problem? {
    let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.isEmpty { return nil }
    if isWildcard(host) { return .wildcardHost(host) }
    if isIPv4(host) || isIPv6(host) { return nil }
    return .invalidHost(host)
  }

  public static func isWildcard(_ host: String) -> Bool {
    if host == "*" { return true }
    var v4 = in_addr()
    if inet_pton(AF_INET, host, &v4) == 1 {
      return withUnsafeBytes(of: v4) { $0.allSatisfy { $0 == 0 } }
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, host, &v6) == 1 {
      return withUnsafeBytes(of: v6) { $0.allSatisfy { $0 == 0 } }
    }
    return false
  }

  public static func isIPv4(_ host: String) -> Bool {
    var address = in_addr()
    return inet_pton(AF_INET, host, &address) == 1
  }

  public static func isIPv6(_ host: String) -> Bool {
    var address = in6_addr()
    return inet_pton(AF_INET6, host, &address) == 1
  }

  /// `127.0.0.0/8` and `::1`: the addresses that do not leave the machine.
  public static func isLoopback(_ host: String) -> Bool {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "localhost" { return true }
    var v4 = in_addr()
    if inet_pton(AF_INET, trimmed, &v4) == 1 {
      return withUnsafeBytes(of: v4) { $0[0] == 127 }
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, trimmed, &v6) == 1 {
      let bytes = withUnsafeBytes(of: v6) { Array($0) }
      return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }
    return false
  }

  public static func isPublicURL(_ raw: String) -> Bool {
    guard let components = URLComponents(string: raw),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host,
          !host.isEmpty
    else { return false }
    return true
  }

  /// `host` or `host:port`, as dsh's browser-trust fence expects. No scheme, no
  /// path, no whitespace.
  public static func isTrustedHost(_ raw: String) -> Bool {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return false }
    guard !value.contains("://"), !value.contains("/"), !value.contains("?") else { return false }
    guard !value.contains(where: { $0.isWhitespace }) else { return false }
    if value.hasPrefix("[") {
      guard let close = value.firstIndex(of: "]") else { return false }
      let literal = String(value[value.index(after: value.startIndex)..<close])
      guard isIPv6(literal) else { return false }
      let rest = value[value.index(after: close)...]
      return rest.isEmpty || (rest.hasPrefix(":") && portIsValid(String(rest.dropFirst())))
    }
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 1 { return !parts[0].isEmpty }
    if parts.count == 2 { return !parts[0].isEmpty && portIsValid(String(parts[1])) }
    return false
  }

  private static func portIsValid(_ raw: String) -> Bool {
    guard let port = Int(raw) else { return false }
    return (1...65535).contains(port)
  }
}
