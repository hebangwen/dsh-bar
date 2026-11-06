import Foundation

/// The one command line this app runs to keep the machine awake, and the parser
/// that proves it did the right thing.
///
/// `-i` alone is deliberate:
///
/// | flag | what it asserts | why not |
/// |---|---|---|
/// | `-d` | prevent *idle display* sleep | the display is supposed to go dark |
/// | `-u` | declare the user active | it also resets the display timer, same problem |
/// | `-s` | prevent system sleep (AC only) | narrower on battery, broader in intent |
/// | `-m` | prevent disk sleep | the disk is not the thing at risk |
///
/// `-w <pid>` is what makes the assertion safe to hold: caffeinate exits when the
/// watched process does, so a crashed app cannot leave the machine awake forever.
public enum Caffeinate {
  public static let executable = "/usr/bin/caffeinate"

  /// The flags this app is allowed to pass. Exposed so the check tool asserts the
  /// flag set instead of trusting a comment.
  public static let flags = ["-i"]
  public static let forbiddenFlags = ["-d", "-u", "-s", "-m", "-t"]

  /// The one unavailability reason this app produces itself, named so the UI can
  /// translate it instead of printing an English sentence at a Chinese reader.
  public static let missingReason = "no /usr/bin/caffeinate on this system"

  public static func isAvailable(fileManager: FileManager = .default) -> Bool {
    fileManager.isExecutableFile(atPath: executable)
  }

  /// Nil when there is nothing to assert on: a disabled policy, or a pid that is
  /// not a pid. Callers never build a command line themselves.
  public static func arguments(for policy: SleepPolicy, watching pid: pid_t) -> [String]? {
    guard policy.isEnabled, pid > 0 else { return nil }
    return flags + ["-w", "\(pid)"]
  }

  /// The command line as one line, for the log.
  public static func describe(for policy: SleepPolicy, watching pid: pid_t) -> String? {
    arguments(for: policy, watching: pid).map { ([executable] + $0).joined(separator: " ") }
  }
}

/// One assertion line from `pmset -g assertions`, parsed.
///
/// The point is verification: the app claims the display may sleep, and this turns
/// that claim into something a test can read off the system rather than off a
/// comment. Lines look like
///
///      pid 55077(caffeinate): [0x0002327600018dab] 00:00:01 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
///         Created for PID: 55076.
public struct SleepAssertion: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable, CaseIterable {
    case idleSystem = "PreventUserIdleSystemSleep"
    case idleDisplay = "PreventUserIdleDisplaySleep"
    case systemSleep = "PreventSystemSleep"
    case userActive = "UserIsActive"
    case backgroundTask = "BackgroundTask"
    case other = "other"

    /// Unknown kinds are `.other` rather than a parse failure: `pmset` grows new
    /// line types between releases and that is not this app's problem.
    public init(raw: String) {
      self = Kind(rawValue: raw) ?? .other
    }
  }

  public var pid: Int
  public var processName: String
  public var kind: Kind
  public var name: String
  /// From the `Created for PID:` continuation line, when the assertion has one.
  public var watchedPID: Int?

  public init(
    pid: Int,
    processName: String,
    kind: Kind,
    name: String,
    watchedPID: Int? = nil
  ) {
    self.pid = pid
    self.processName = processName
    self.kind = kind
    self.name = name
    self.watchedPID = watchedPID
  }

  /// Only the assertions the caffeinate tool itself owns.
  public static func caffeinateAssertions(in listing: String) -> [SleepAssertion] {
    parse(listing).filter { $0.processName == "caffeinate" }
  }

  public static func parse(_ listing: String) -> [SleepAssertion] {
    var found: [SleepAssertion] = []
    var current: SleepAssertion?
    for line in listing.split(separator: "\n", omittingEmptySubsequences: false) {
      let text = String(line)
      if let record = record(in: text) {
        if let current { found.append(current) }
        current = record
        continue
      }
      // The `Created for PID:` line belongs to the record above it, so it edits
      // the pending record rather than starting a new one.
      if var pending = current, let watched = watchedPID(in: text) {
        pending.watchedPID = watched
        current = pending
      }
    }
    if let current { found.append(current) }
    return found
  }

  // `   pid 55077(caffeinate): [0x…] 00:00:01 PreventUserIdleSystemSleep named: "…"  `
  // The duration can exceed a day (`48:34:03`), so it is matched as digits and
  // colons rather than as a time.
  private static let recordPattern = try! NSRegularExpression(
    pattern: #"^\s+pid\s+(\d+)\(([^)]*)\):\s+\[[^\]]*\]\s+[\d:]+\s+(\w+)\s+named:\s*"(.*)"\s*$"#
  )
  private static let watchedPattern = try! NSRegularExpression(
    pattern: #"Created for PID:\s*(\d+)"#
  )

  private static func record(in line: String) -> SleepAssertion? {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = recordPattern.firstMatch(in: line, range: range) else { return nil }
    func group(_ index: Int) -> String? {
      guard let range = Range(match.range(at: index), in: line) else { return nil }
      return String(line[range])
    }
    guard let pid = group(1).flatMap(Int.init), let raw = group(3) else { return nil }
    return SleepAssertion(
      pid: pid,
      processName: group(2) ?? "",
      kind: Kind(raw: raw),
      name: group(4) ?? ""
    )
  }

  private static func watchedPID(in line: String) -> Int? {
    let range = NSRange(line.startIndex..., in: line)
    guard
      let match = watchedPattern.firstMatch(in: line, range: range),
      let captured = Range(match.range(at: 1), in: line)
    else { return nil }
    return Int(line[captured])
  }
}
