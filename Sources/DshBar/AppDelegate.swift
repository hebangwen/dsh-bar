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
  private let hotKey = HotKeyCenter()
  private var showPanelObserver: NSObjectProtocol?
  /// The answer to "keep it running?" when the quit policy is `ask`.
  private var quitKeepsServer = false

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
    installHotKey()
    installShowPanelObserver()

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

  /// The question is asked *before* termination starts. `applicationWillTerminate`
  /// runs after the app has begun tearing down, and a modal there can hold up a
  /// logout or a `SIGTERM` that arrived from outside.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let ownsServer = model.snapshot.phase == .listening && model.snapshot.owner == .dshBar
    guard ownsServer, model.effectiveQuitBehavior == .ask else { return .terminateNow }
    quitKeepsServer = askWhetherToKeep()
    return .terminateNow
  }

  /// Quitting is where the "keep it running" preference is honoured. The choice is
  /// made once, here, for a server this app actually owns; an external one was
  /// never ours to stop.
  func applicationWillTerminate(_ notification: Notification) {
    let behavior = model.effectiveQuitBehavior
    let ownsServer = model.snapshot.phase == .listening && model.snapshot.owner == .dshBar
    guard ownsServer else {
      model.shutdown()
      return
    }
    switch behavior {
    case .stopManaged:
      model.shutdown()
    case .keepRunning:
      model.keepRunning()
    case .ask:
      quitKeepsServer ? model.keepRunning() : model.shutdown()
    }
  }

  /// The three-way quit, asked once at the moment it matters. Returns `true` when
  /// the server should be left alive.
  private func askWhetherToKeep() -> Bool {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = model.copy.quitAskTitle
    alert.informativeText = model.copy.quitAskBody
    alert.addButton(withTitle: model.copy.quitAskStop)
    alert.addButton(withTitle: model.copy.quitAskKeep)
    let remember = NSButton(checkboxWithTitle: model.copy.quitAskRemember, target: nil, action: nil)
    remember.state = .off
    alert.accessoryView = remember
    let keep = alert.runModal() == .alertSecondButtonReturn
    if remember.state == .on {
      model.update(quitBehavior: keep ? .keepRunning : .stopManaged)
    }
    return keep
  }

  // MARK: - Panel actions

  private func handle(_ action: PanelAction) {
    switch action {
    case .primary:
      switch model.snapshot.phase {
      case .stopped, .failed: startFromPanel()
      case .listening: openLaunchURL()
      case .unavailable: chooseBinary()
      case .starting, .stopping: break
      }
    case .secondary:
      switch model.snapshot.phase {
      case .listening: model.stop()
      case .starting: model.cancel()
      case .failed:
        // The second button is the repair the diagnosis suggests; retry is the
        // first. Each recovery is one preference change away from a usable launch.
        switch model.snapshot.failure?.recovery {
        case .freePort:
          // Port 0 asks the OS and adopts what it gives back.
          model.update(port: BarPreferences.autoPort)
        case .defaultPaths:
          model.resetLaunchPaths()
        case nil:
          break
        }
        startFromPanel()
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

  /// Every path that starts the server comes through here.
  ///
  /// The `~/Documents` grant is asked for at this click, not at launch: that is the
  /// moment the folder is actually needed, and it keeps an idle menu bar app from
  /// putting a dialog on screen. The status panel is folded away first so the open
  /// panel is the only thing asking for attention.
  private func startFromPanel() {
    if model.owesDocumentsGrant {
      panel.hide(returnFocus: false)
    }
    model.start()
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
        contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.width, height: SettingsMetrics.height),
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
    NSApp.activate()
    settingsWindow?.makeKeyAndOrderFront(nil)

    // `DSHBAR_SNAPSHOT_SETTINGS=<path>` renders the sheet offscreen, the same way
    // dshbar-snap renders the panel: cacheDisplay drops most SwiftUI layers, so
    // ImageRenderer is the only honest copy of what this window looks like.
    if let path = ProcessInfo.processInfo.environment["DSHBAR_SNAPSHOT_SETTINGS"] {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
        guard let self else { return }
        let base = URL(fileURLWithPath: path)
        let stem = base.deletingPathExtension().lastPathComponent
        let folder = base.deletingLastPathComponent()
        // One PNG per pane: the tab strip means a single render can no longer show
        // the whole window, and the review sheets want every pane.
        let wantsDark = ProcessInfo.processInfo.environment["DSHBAR_SNAPSHOT_DARK"] == "1"
        for tab in SettingsTab.allCases {
          for scheme in wantsDark ? [ColorScheme.light, .dark] : [ColorScheme.light] {
            // A settings window has no plate of its own — the window background
            // provides it. Offscreen there is no window, so the renderer paints the
            // scheme's plate itself, otherwise the dark pass is white on white.
            let renderer = ImageRenderer(
              content: SettingsView(model: self.model, scrolls: false, tab: tab)
                .frame(width: SettingsMetrics.width, height: SettingsMetrics.snapshotHeight)
                .background(Palette.forScheme(scheme).plate)
                .environment(\.colorScheme, scheme)
            )
            renderer.scale = 2
            guard
              let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:])
            else { continue }
            var name = tab == .general ? base.lastPathComponent : "\(stem)-\(tab.rawValue).png"
            if scheme == .dark {
              name = (name as NSString).deletingPathExtension + "-dark.png"
            }
            try? data.write(to: folder.appendingPathComponent(name))
          }
        }
      }
    }
  }

  // MARK: - Shortcut & second launch

  private func installHotKey() {
    hotKey.onTrigger = { [weak self] in
      guard let self else { return }
      self.panel.toggle(relativeTo: self.status.button)
    }
    model.onHotKeyChange = { [weak self] choice in
      self?.applyHotKey(choice)
    }
    applyHotKey(model.preferences.hotKey)
  }

  /// Register the chord and remember what actually happened.
  ///
  /// A failure is **not** written into the preference: "taken" is often transient
  /// (another copy of the app is running, or the user is about to free the chord),
  /// and silently rewriting someone's setting because of it is worse than showing
  /// the red line and letting them choose.
  @discardableResult
  private func applyHotKey(_ choice: HotKeyChoice) -> HotKeyStatus {
    let status = hotKey.apply(choice)
    model.recordHotKeyStatus(status)
    return status
  }

  /// A second `open` of the same bundle lands here: this copy shows its panel
  /// instead of the user getting a second, invisible menu bar icon.
  private func installShowPanelObserver() {
    showPanelObserver = DistributedNotificationCenter.default().addObserver(
      forName: SingleInstance.showPanelNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.panel.show(relativeTo: self.status.button)
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
