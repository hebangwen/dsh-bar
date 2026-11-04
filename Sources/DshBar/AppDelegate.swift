import AppKit
import DshBarKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let model = HarnessModel()
  private var panel: PanelWindowController!
  private var status: StatusItemController!
  private var settingsWindow: NSWindow?
  private var terminationSource: DispatchSourceSignal?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    model.refreshDetection()
    installTerminationHandler()

    panel = PanelWindowController(model: model) { [weak self] action in
      self?.handle(action)
    }
    status = StatusItemController(
      model: model,
      panel: panel,
      onSettings: { [weak self] in self?.openSettings() },
      onQuit: { NSApp.terminate(nil) }
    )
    status.install()

    // The port may already serve a dsh someone started in a terminal; look once at
    // launch so the panel opens telling the truth.
    model.refreshExternal()

    // `DSHBAR_OPEN_PANEL=1` opens the panel on launch: used to verify layout
    // and positioning without clicking the menu bar.
    if model.demoMode,
       let scene = ProcessInfo.processInfo.environment["DSHBAR_STATE"],
       let fixture = DemoScene(rawValue: scene) {
      model.jump(to: fixture)
    }

    if ProcessInfo.processInfo.environment["DSHBAR_OPEN_SETTINGS"] == "1" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.openSettings()
      }
    }

    if ProcessInfo.processInfo.environment["DSHBAR_OPEN_PANEL"] == "1" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        guard let self else { return }
        self.panel.show(relativeTo: self.status.button)
      }
    }

    // Debug hooks: drive the live path without a click, for the integration pass.
    // `DSHBAR_AUTOSTART=1` starts once; `DSHBAR_AUTORESTART=1` also presses
    // Restart a few seconds later, which exercises stop → settle → start.
    if ProcessInfo.processInfo.environment["DSHBAR_AUTOSTART"] == "1" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.model.start()
      }
    }
    if ProcessInfo.processInfo.environment["DSHBAR_AUTORESTART"] == "1" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [weak self] in
        self?.model.restart()
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// `kill` must stop the managed server, not orphan it. Ignoring the default
  /// action and routing SIGTERM through AppKit runs the same path the Quit menu
  /// does, so the child gets its graceful stop.
  private func installTerminationHandler() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
      NSApp.terminate(nil)
    }
    source.resume()
    terminationSource = source
  }

  /// A managed server must not outlive the app that started it: the panel is the
  /// only place that knows the token and the pid.
  func applicationWillTerminate(_ notification: Notification) {
    model.shutdown()
  }

  // MARK: - Panel actions

  private func handle(_ action: PanelAction) {
    switch action {
    case .primary:
      switch model.snapshot.phase {
      case .stopped, .failed: model.start()
      case .listening: openLaunchURL()
      case .unavailable: chooseBinary()
      case .starting, .stopping: break
      }
    case .secondary:
      switch model.snapshot.phase {
      case .listening: model.stop()
      case .starting: model.cancel()
      case .failed:
        // "Use a free port" is the second button on a port failure; retry is the
        // first. Port 0 asks the OS and adopts what it gives back.
        if model.snapshot.failure?.port != nil {
          model.update(port: BarPreferences.autoPort)
        }
        model.start()
      default: break
      }
    case .restart:
      model.restart()
    case .copyLink:
      model.copyLink()
    case .takeOver:
      model.takeOver()
    case .openLog:
      openLog()
    case .settings:
      openSettings()
    case .quit:
      NSApp.terminate(nil)
    case .chooseBinary:
      chooseBinary()
    }
  }

  private func openLaunchURL() {
    // An external server has no token to append; opening its root still lands on
    // the dsh page (or its 401 fence), which is the best this app can offer.
    let string = model.launchURL ?? "http://\(model.snapshot.address)/"
    guard let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
    panel.hide(returnFocus: false)
  }

  private func openSettings() {
    if settingsWindow == nil {
      let hosting = NSHostingView(rootView: SettingsView(model: model))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 312),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.title = model.copy.settings
      window.contentView = hosting
      window.isReleasedWhenClosed = false
      window.center()
      settingsWindow = window
    }
    panel.hide(returnFocus: false)
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)

    // `DSHBAR_SNAPSHOT_SETTINGS=<path>` renders the sheet offscreen, the same way
    // dshbar-snap renders the panel: cacheDisplay drops most SwiftUI layers, so
    // ImageRenderer is the only honest copy of what this window looks like.
    if let path = ProcessInfo.processInfo.environment["DSHBAR_SNAPSHOT_SETTINGS"] {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
        guard let self else { return }
        let renderer = ImageRenderer(
          content: SettingsView(model: self.model).frame(width: 460, height: 312)
        )
        renderer.scale = 2
        guard
          let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
      }
    }
  }

  private func chooseBinary() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.message = model.copy.chooseBinary
    panel.prompt = model.copy.change
    if panel.runModal() == .OK, let url = panel.url {
      model.chooseBinary(url.path)
    }
  }

  /// Opens the log the running server is writing to, creating it on first use so
  /// the menu item is real before anything has started.
  private func openLog() {
    let fileManager = FileManager.default
    try? fileManager.createDirectory(at: DshBarPaths.logDirectory, withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: DshBarPaths.logFile.path) {
      fileManager.createFile(atPath: DshBarPaths.logFile.path, contents: nil)
    }
    NSWorkspace.shared.open(DshBarPaths.logFile)
    panel.hide(returnFocus: false)
  }
}
