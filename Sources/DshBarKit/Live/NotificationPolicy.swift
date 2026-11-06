import Foundation

/// What the system currently allows this app to say out loud.
public enum NotificationPermission: String, Sendable, Equatable, CaseIterable {
  /// Never asked, or the answer is not readable yet.
  case unknown
  case notDetermined
  case allowed
  case denied
  /// Not running from a bundle (the check/smoke tools), so there is no
  /// notification centre to talk to.
  case unavailable
}

/// A transition worth a system notification.
///
/// The app is a menu bar utility: nobody is watching it, so the moments that
/// matter are exactly the ones the panel cannot show while it is closed.
public enum NotificationEvent: Sendable, Equatable {
  case startFailed(HarnessFailure)
  /// The server died while it was serving. `restarting` says whether the watchdog
  /// is about to try again, and `attempt` which try this is.
  case crashed(failure: HarnessFailure, restarting: Bool, attempt: Int?)
  /// The watchdog used its whole budget.
  case restartGaveUp(attempts: Int)
  /// Stop was pressed and the server is still holding the port.
  case stopFailed(HarnessFailure)
}

public enum NotificationPolicy {
  /// The decision table, as one function: a notification is about a *transition*,
  /// never about a state, so a panel reopened on a failed server stays quiet.
  public static func event(previous: HarnessSnapshot, next: HarnessSnapshot) -> NotificationEvent? {
    switch (previous.phase, next.phase) {
    case (.starting, .failed):
      return next.failure.map { .startFailed($0) }
    case (.listening, .failed):
      return next.failure.map { .crashed(failure: $0, restarting: false, attempt: nil) }
    case (.listening, .restarting):
      return next.failure.map {
        .crashed(failure: $0, restarting: true, attempt: next.restartAttempt)
      }
    case (.restarting, .failed):
      return .restartGaveUp(attempts: previous.restartAttempt ?? CrashWatchdog.maxAttempts)
    case (.stopping, .failed):
      return next.failure.map { .stopFailed($0) }
    default:
      return nil
    }
  }

  /// A stable identifier per kind, so a second crash of the same server replaces
  /// the first notification instead of stacking a column of them.
  public static func identifier(_ event: NotificationEvent) -> String {
    switch event {
    case .startFailed: return "dev.dsh.bar.start-failed"
    case .crashed: return "dev.dsh.bar.crashed"
    case .restartGaveUp: return "dev.dsh.bar.restart-gave-up"
    case .stopFailed: return "dev.dsh.bar.stop-failed"
    }
  }
}
