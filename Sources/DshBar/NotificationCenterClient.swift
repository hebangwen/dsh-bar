import DshBarKit
import Foundation
import UserNotifications

/// Who can post a notification, as a protocol so the smoke tool can count instead
/// of showing banners on a machine somebody is looking at.
@MainActor
protocol CrashNotifier: AnyObject {
  var permission: NotificationPermission { get }
  func refreshPermission()
  /// Asks the system once; a second ask does nothing, which is the system's rule.
  func requestAuthorization()
  func post(_ event: NotificationEvent, copy: Copy, enabled: Bool)
  func clearDelivered()
}

/// The real one: `UNUserNotificationCenter`, which needs a bundled app.
///
/// `UNUserNotificationCenter.current()` raises when the process is not a bundle,
/// and `dshbar-check` / `dshbar-smoke` are bare executables, so the whole surface
/// hides behind `isBundled` and `notificationAvailable` rather than crashing a
/// command-line tool.
@MainActor
final class NotificationCenterClient: CrashNotifier {
  static let system = NotificationCenterClient()

  /// Set by the app delegate: clicking the notification is the shortest path from
  /// "it broke" to "tell me what to do about it".
  var onActivate: (() -> Void)?

  private let bundled: Bool
  private var cached: NotificationPermission = .unknown
  private(set) var posted: [NotificationEvent] = []

  init(bundled: Bool = Bundle.main.bundleIdentifier != nil) {
    self.bundled = bundled
    guard bundled else { return }
    // A weak proxy: the centre holds its delegate strongly enough to keep a
    // closed window alive otherwise.
    delegateProxy.owner = self
    UNUserNotificationCenter.current().delegate = delegateProxy
  }

  private let delegateProxy = NotificationDelegate()

  var isBundled: Bool { bundled }

  var permission: NotificationPermission {
    guard bundled else { return .unavailable }
    return cached
  }

  /// Reads the current authorization, off the main actor and back on it.
  func refreshPermission() {
    guard bundled else { return }
    centers().getNotificationSettings { settings in
      let mapped = Self.map(settings.authorizationStatus)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.cached = mapped
        }
      }
    }
  }

  func requestAuthorization() {
    guard bundled else { return }
    centers().requestAuthorization(options: [.alert, .sound]) { granted, _ in
      let mapped: NotificationPermission = granted ? .allowed : .denied
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          self.cached = mapped
        }
      }
    }
  }

  func post(_ event: NotificationEvent, copy: Copy, enabled: Bool) {
    posted.append(event)
    guard bundled, enabled, cached == .allowed else { return }
    let content = UNMutableNotificationContent()
    content.title = copy.notificationTitle(event)
    content.body = copy.notificationBody(event)
    content.sound = .default
    content.userInfo = ["start": true]
    let request = UNNotificationRequest(
      identifier: NotificationPolicy.identifier(event),
      content: content,
      trigger: nil
    )
    centers().add(request) { _ in }
  }

  func clearDelivered() {
    guard bundled else { return }
    centers().removeAllDeliveredNotifications()
  }

  private func centers() -> UNUserNotificationCenter {
    UNUserNotificationCenter.current()
  }

  static func map(_ status: UNAuthorizationStatus) -> NotificationPermission {
    switch status {
    case .notDetermined: return .notDetermined
    case .denied: return .denied
    case .authorized, .provisional, .ephemeral: return .allowed
    @unknown default: return .unknown
    }
  }

  /// The one deeplink Apple documents for the Notifications pane.
  static let settingsURL = "x-apple.systempreferences:com.apple.preference.notifications"
}


/// `UNUserNotificationCenterDelegate` is a class protocol, and the centre keeps it
/// unowned-but-strong; a tiny proxy keeps the client out of a retain cycle.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
  weak var owner: NotificationCenterClient?

  /// A foreground app shows no banner by default; this app is a menu bar utility,
  /// so "foreground" is a technicality — the banner is the whole point.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.owner?.onActivate?()
      }
    }
  }
}
