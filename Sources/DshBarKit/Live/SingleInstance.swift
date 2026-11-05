import AppKit
import Foundation

/// One app, one menu bar icon.
///
/// `LSUIElement` apps have no Dock icon and no window to bring forward, so a second
/// launch is invisible: the user gets a second glyph and two controllers racing for
/// the same port. The decision is kept pure — it takes the process list as data —
/// so the "who wins" rule can be checked without launching anything twice.
public enum SingleInstance {
  public struct Resident: Sendable, Equatable {
    public var pid: pid_t
    public var bundleIdentifier: String?

    public init(pid: pid_t, bundleIdentifier: String?) {
      self.pid = pid
      self.bundleIdentifier = bundleIdentifier
    }
  }

  public enum Decision: Sendable, Equatable {
    /// No other copy is running: this process owns the menu bar.
    case runMyself
    /// Another copy is already up; hand the click to it and leave.
    case yield(to: pid_t)
  }

  /// Posted by the copy that lost the race. The running copy shows its panel.
  public static let showPanelNotification = Notification.Name("dev.dsh.bar.showPanel")

  /// The first *other* process with the same bundle identifier wins. Unbundled
  /// builds (`swift run DshBar`) have no identifier and always run, which is what
  /// makes the debug launch usable next to the installed app.
  public static func decision(
    running: [Resident],
    myPID: pid_t,
    myBundleIdentifier: String?
  ) -> Decision {
    guard let identifier = myBundleIdentifier, !identifier.isEmpty else { return .runMyself }
    let others = running
      .filter { $0.pid != myPID && $0.bundleIdentifier == identifier }
      .sorted { $0.pid < $1.pid }
    guard let first = others.first else { return .runMyself }
    return .yield(to: first.pid)
  }

  /// The live process list, in the shape `decision` takes.
  public static func residents() -> [Resident] {
    NSWorkspace.shared.runningApplications.map {
      Resident(pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
    }
  }

  /// Ask the running copy to show its panel, and bring it forward as a fallback.
  public static func handOver(to pid: pid_t) {
    DistributedNotificationCenter.default().postNotificationName(
      showPanelNotification,
      object: nil,
      userInfo: nil,
      deliverImmediately: true
    )
    NSRunningApplication(processIdentifier: pid)?.activate()
    // The notification is delivered by another process; returning immediately can
    // exit before it is sent, and then a second `open` looks like it did nothing.
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
  }
}
