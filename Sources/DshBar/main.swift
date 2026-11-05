import AppKit
import DshBarKit

// `dsh bar` lives in the menu bar only: no Dock icon, no main window.
@MainActor
enum Launcher {
  private static var delegate: AppDelegate?

  static func run() {
    // A menu bar app has no window to raise, so a second `open` would otherwise be a
    // second invisible icon fighting for the same port. Decide before anything is
    // constructed: no timers, no status item, no spawn.
    //
    // `DSHBAR_ALLOW_SECOND_INSTANCE=1` is the documented way to run a second copy for
    // screenshots and integration work; without it the rule would make those
    // impossible on any machine that already has dsh bar in the menu bar.
    let allowsSecond = ProcessInfo.processInfo.environment["DSHBAR_ALLOW_SECOND_INSTANCE"] == "1"
    let decision = allowsSecond ? .runMyself : SingleInstance.decision(
      running: SingleInstance.residents(),
      myPID: getpid(),
      myBundleIdentifier: Bundle.main.bundleIdentifier
    )
    if case let .yield(to: resident) = decision {
      SingleInstance.handOver(to: resident)
      return
    }

    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    delegate = appDelegate
    application.delegate = appDelegate
    application.run()
  }
}

MainActor.assumeIsolated {
  Launcher.run()
}
