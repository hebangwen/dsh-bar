import Foundation

/// What the login shell actually gave the app, as one value.
///
/// The environment is the least visible part of a launch and the most common
/// reason one fails, so what the resolver learned is kept as data the settings
/// window can show: where it came from, what PATH starts with, which node it
/// found, and how long asking took.
public struct EnvironmentReport: Sendable, Equatable {
  public var source: LoginShellEnvironment.Source
  public var variableCount: Int
  /// The first three PATH entries, joined — enough to see nvm / Homebrew lead it.
  public var pathHead: String
  public var nodePath: String?
  public var nodeVersion: String?
  /// How long the shell round-trip took. A `zsh -lic` that reads a heavy `.zshrc`
  /// is worth seeing next to the number it costs.
  public var durationMs: Int
  public var resolvedAt: Date
  /// Set when the answer is not trustworthy: no shell, or a shell without node.
  public var failureNote: String?

  public init(
    source: LoginShellEnvironment.Source,
    variableCount: Int,
    pathHead: String,
    nodePath: String?,
    nodeVersion: String?,
    durationMs: Int,
    resolvedAt: Date,
    failureNote: String? = nil
  ) {
    self.source = source
    self.variableCount = variableCount
    self.pathHead = pathHead
    self.nodePath = nodePath
    self.nodeVersion = nodeVersion
    self.durationMs = durationMs
    self.resolvedAt = resolvedAt
    self.failureNote = failureNote
  }

  public var hasNode: Bool { nodePath != nil }

  /// Whether the settings row should warn. A `process` source means no shell
  /// answered at all — the app's own PATH has neither node nor nvm.
  public var isDegraded: Bool {
    source == .process || nodePath == nil
  }

  public static let headLength = 3

  /// Build a report from a resolved environment. Pure: the caller does the I/O, so
  /// the shape of what the row prints is assertable without a shell.
  public static func make(
    values: [String: String],
    source: LoginShellEnvironment.Source,
    durationMs: Int,
    resolvedAt: Date = Date(),
    nodeVersion: String? = nil,
    nodePath: String? = nil
  ) -> EnvironmentReport {
    let path = values["PATH"] ?? ""
    let resolvedNode = nodePath ?? LoginShellEnvironment.nodePath(onPath: path)
    var note: String?
    switch source {
    case .process:
      note = "no shell answered"
    case .loginShell:
      note = "only the login shell answered; ~/.zshrc exports are missing"
    case .interactiveShell:
      note = nil
    }
    if resolvedNode == nil {
      note = (note.map { $0 + "; " } ?? "") + "no node on PATH"
    }
    return EnvironmentReport(
      source: source,
      variableCount: values.count,
      pathHead: head(of: path),
      nodePath: resolvedNode,
      nodeVersion: nodeVersion,
      durationMs: durationMs,
      resolvedAt: resolvedAt,
      failureNote: note
    )
  }

  /// `a:/b:/c`, and nothing invented when PATH is shorter than that.
  public static func head(of path: String, limit: Int = headLength) -> String {
    let entries = path
      .split(separator: ":", omittingEmptySubsequences: true)
      .prefix(limit)
      .map(String.init)
    return entries.joined(separator: ":")
  }
}
