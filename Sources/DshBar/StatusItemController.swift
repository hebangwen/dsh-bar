import AppKit
import Combine
import DshBarKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private let model: HarnessModel
  private let panel: PanelWindowController
  private let onSettings: () -> Void
  private let onQuit: () -> Void
  private var statusItem: NSStatusItem!
  private var cancellables = Set<AnyCancellable>()
  private var animationTimer: Timer?
  /// Layers the app owns while a state animates. They are never the button's own
  /// layer: AppKit anchors that one at `(0, 0)`, which turns any rotation into a
  /// swing around the button's corner.
  private var artLayers: [CALayer] = []
  private var frameIndex = 0
  private var lastKey: String?
  private var themeObserver: NSObjectProtocol?

  var button: NSStatusBarButton? { statusItem?.button }

  init(
    model: HarnessModel,
    panel: PanelWindowController,
    onSettings: @escaping () -> Void,
    onQuit: @escaping () -> Void
  ) {
    self.model = model
    self.panel = panel
    self.onSettings = onSettings
    self.onQuit = onQuit
    super.init()
  }

  deinit {
    if let themeObserver {
      DistributedNotificationCenter.default.removeObserver(themeObserver)
    }
  }

  func install() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = statusItem.button else { return }
    button.target = self
    button.action = #selector(handleClick)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])

    model.$snapshot
      .sink { [weak self] snapshot in self?.apply(snapshot) }
      .store(in: &cancellables)

    // A layer's colour is fixed when it is created, so a menu bar that flips
    // between light and dark needs the glyph rebuilt in the new colour.
    themeObserver = DistributedNotificationCenter.default.addObserver(
      forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.lastKey = nil
        self.apply(self.model.snapshot)
      }
    }
  }

  private func apply(_ snapshot: HarnessSnapshot) {
    guard let button = statusItem.button else { return }

    // The snapshot also ticks every second for uptime; the glyph only needs to
    // change when the state itself does, or the animation would restart.
    let key = "\(snapshot.phase.rawValue)|\(snapshot.owner)|\(snapshot.port)"
    guard key != lastKey else { return }
    let hadPrevious = lastKey != nil
    lastKey = key

    let copy = model.copy
    let state = copy.stateWord(snapshot.phase)
    button.toolTip = snapshot.phase == .listening
      ? "dsh bar — \(state) \(snapshot.port)"
      : "dsh bar — \(state)"
    button.setAccessibilityLabel(button.toolTip)

    stopAnimation()

    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      button.image = StatusIcon.image(for: snapshot.phase, owner: snapshot.owner)
      return
    }

    if snapshot.phase == .starting || snapshot.phase == .stopping {
      // A layer rotation is composited by the window server, so a long boot
      // costs nothing; swapping 18pt images twenty times a second does not.
      button.image = StatusIcon.image(for: snapshot.phase, owner: snapshot.owner)
      startSpin(
        on: button,
        clockwise: snapshot.phase == .starting,
        secondsPerTurn: snapshot.phase == .starting ? 1.1 : 1.4
      )
    } else if snapshot.phase == .listening {
      if snapshot.owner == .external {
        button.image = StatusIcon.image(for: .listening, owner: .external)
      } else if hadPrevious {
        // One arrival pulse, then settle into the slow breath.
        play(StatusIcon.arrivalPulse(for: snapshot.owner), settlingOn: nil) { [weak self] in
          guard let self, let button = self.statusItem.button else { return }
          self.startListeningBreathe(on: button)
        }
      } else {
        startListeningBreathe(on: button)
      }
    } else {
      button.image = StatusIcon.image(for: snapshot.phase, owner: snapshot.owner)
    }
  }

  // MARK: - Motion

  /// Cycles 18pt frames at 20 fps — cheap enough to only run while a state is
  /// actually changing, and it stops on the frame that settles the state.
  private func play(
    _ frames: [NSImage],
    settlingOn settle: NSImage?,
    completion: (() -> Void)? = nil
  ) {
    guard let first = frames.first, let button = statusItem.button else { return }
    button.image = first
    frameIndex = 0
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self, let button = self.statusItem?.button else {
          timer.invalidate()
          return
        }
        self.frameIndex += 1
        if self.frameIndex >= frames.count {
          if let settle {
            button.image = settle
          }
          self.stopAnimation()
          completion?()
          return
        }
        button.image = frames[self.frameIndex]
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    animationTimer = timer
  }

  /// The transitional glyph is a bitmap layer of our own, not the button's layer:
  /// AppKit anchors that one at `(0, 0)`, so rotating it turns the icon around
  /// the button's corner and throws it out of the menu bar.
  ///
  /// It is a bitmap rather than a `CAShapeLayer` because a shape is re-rasterised
  /// on every composite — sixty vector redraws a second of the menu bar, which
  /// showed up as ~50% window-server CPU. A texture is merely scaled and rotated
  /// by the compositor. The frame-rate cap keeps the rest honest.
  private func startSpin(on button: NSStatusBarButton, clockwise: Bool, secondsPerTurn: Double) {
    stopArt()
    button.wantsLayer = true
    guard let host = button.layer else { return }

    let side: CGFloat = 18
    let layer = CALayer()
    layer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
    layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    layer.position = glyphCenter(in: host, side: side)
    layer.contents = StatusIcon.bitmap(
      for: .starting,
      owner: .dshBar,
      color: glyphColor(for: button)
    )
    layer.contentsScale = 2
    host.addSublayer(layer)
    artLayers = [layer]

    // The template image would draw a second, static glyph underneath.
    button.image = nil

    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0
    spin.toValue = (clockwise ? -1.0 : 1.0) * 2 * Double.pi
    spin.duration = secondsPerTurn
    spin.repeatCount = .infinity
    spin.isRemovedOnCompletion = false
    spin.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: 20, preferred: 15)
    layer.add(spin, forKey: "dsh.spin")
  }

  /// While the server is up, the dot breathes: it is the one piece of motion the
  /// app keeps running, so "alive" stays readable at a glance.
  ///
  /// The ring stays a template image (the menu bar tints it, no layer needed) and
  /// only the dot is a layer, so exactly one small texture is composited per
  /// frame — and only at the capped frame rate.
  private func startListeningBreathe(on button: NSStatusBarButton) {
    stopArt()
    button.wantsLayer = true
    guard let host = button.layer else { return }

    let side: CGFloat = 18
    button.image = StatusIcon.listeningRingImage()

    let dot = CALayer()
    dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
    dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    dot.position = glyphCenter(in: host, side: side)
    dot.contents = StatusIcon.dotBitmap(color: glyphColor(for: button))
    dot.contentsScale = 2
    host.addSublayer(dot)
    artLayers = [dot]

    let breathe = CABasicAnimation(keyPath: "transform.scale")
    breathe.fromValue = 1.0
    breathe.toValue = 1.26
    breathe.duration = 1.3
    breathe.autoreverses = true
    breathe.repeatCount = .infinity
    breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    breathe.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 12)
    dot.add(breathe, forKey: "dsh.breathe")
  }

  private func stopArt() {
    for layer in artLayers {
      layer.removeFromSuperlayer()
    }
    artLayers = []
  }

  private func stopAnimation() {
    animationTimer?.invalidate()
    animationTimer = nil
    stopArt()
  }

  private func glyphCenter(in host: CALayer, side: CGFloat) -> CGPoint {
    host.bounds.isEmpty
      ? CGPoint(x: side / 2, y: side / 2)
      : CGPoint(x: host.bounds.midX, y: host.bounds.midY)
  }

  /// Template images take their colour from the menu bar; a layer's contents do
  /// not, so the colour is resolved from the button's own appearance.
  private func glyphColor(for button: NSStatusBarButton) -> NSColor {
    button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? .white
      : .black
  }

  // MARK: - Menu

  @objc private func handleClick() {
    if NSApp.currentEvent?.type == .rightMouseUp {
      presentMenu()
    } else {
      panel.toggle(relativeTo: statusItem.button)
    }
  }

  private func presentMenu() {
    let menu = NSMenu()
    menu.delegate = self

    let open = NSMenuItem(title: model.copy.wordmark, action: nil, keyEquivalent: "")
    open.isEnabled = false
    menu.addItem(open)

    menu.addItem(.separator())

    // Preview scenes are a design tool: they exist only in demo mode, so a real
    // user can never put the panel into a state the panel's process is not in.
    if model.demoMode {
      let scenes = NSMenu()
      for scene in DemoScene.allCases {
        let item = NSMenuItem(title: scene.title, action: #selector(selectScene(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = scene.rawValue
        item.state = currentScene == scene ? .on : .off
        scenes.addItem(item)
      }
      let sceneItem = NSMenuItem(
        title: model.language == .zhHans ? "外观预览状态" : "Preview state",
        action: nil,
        keyEquivalent: ""
      )
      sceneItem.submenu = scenes
      menu.addItem(sceneItem)
      menu.addItem(.separator())
    }

    let settings = NSMenuItem(title: model.copy.settings, action: #selector(openSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)

    let quit = NSMenuItem(title: model.copy.quit, action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)

    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  private var currentScene: DemoScene? {
    switch model.snapshot.phase {
    case .unavailable: return .unavailable
    case .stopped: return .stopped
    case .starting: return .starting
    case .stopping: return .stopping
    case .failed: return model.snapshot.failure?.port == nil ? .failedExit : .failedPort
    case .listening: return model.snapshot.owner == .external ? .listeningExternal : .listening
    }
  }

  @objc private func selectScene(_ sender: NSMenuItem) {
    guard
      let raw = sender.representedObject as? String,
      let scene = DemoScene(rawValue: raw)
    else { return }
    model.jump(to: scene)
  }

  @objc private func openSettings() {
    onSettings()
  }

  @objc private func quit() {
    onQuit()
  }
}
