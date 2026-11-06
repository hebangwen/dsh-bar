import Foundation

/// What to do about a crash, as a value.
///
/// A server that dies while it was serving is the one failure this app can repair
/// by itself, so it does — but not forever. Three attempts inside two minutes is
/// the budget: enough to ride out a transient port race or a plugin that needed a
/// second boot, few enough that a real breakage stops instead of burning the
/// machine. The window is why a healthy run for an hour resets the count without
/// anybody clearing it.
public enum CrashWatchdog {
  public static let maxAttempts = 3
  public static let baseDelay = 1
  public static let maxDelay = 8
  /// Attempts older than this no longer count against the budget.
  public static let window: TimeInterval = 120

  /// 1, 2, 4, 8, 8, … seconds. The first retry is immediate enough to feel like a
  /// recovery; the cap keeps a broken plugin from being hammered.
  public static func delay(attempt: Int) -> Int {
    guard attempt > 1 else { return baseDelay }
    let shifted = baseDelay << min(attempt - 1, 4)
    return min(shifted, maxDelay)
  }

  public static func recentAttempts(_ attempts: [Date], now: Date) -> [Date] {
    attempts.filter { now.timeIntervalSince($0) < window }
  }

  /// The whole decision, in one place, so the reducer and the checks agree.
  public static func decide(attempts: [Date], now: Date) -> CrashDecision {
    let recent = recentAttempts(attempts, now: now)
    guard recent.count < maxAttempts else { return .giveUp(attempts: recent.count) }
    let attempt = recent.count + 1
    return .restart(attempt: attempt, delay: delay(attempt: attempt))
  }
}

public enum CrashDecision: Sendable, Equatable {
  case restart(attempt: Int, delay: Int)
  case giveUp(attempts: Int)
}
