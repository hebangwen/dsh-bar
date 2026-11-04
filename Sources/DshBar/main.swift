import AppKit

// `dsh bar` lives in the menu bar only: no Dock icon, no main window.
@MainActor
enum Launcher {
  private static var delegate: AppDelegate?

  static func run() {
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
