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
  private var spinShape: CAShapeLayer?
  private var frameIndex = 0
  private var lastKey: String?

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

  func install() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = statusItem.button else { return }
    button.target = self
    button.action = #selector(handleClick)
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])

    model.$snapshot
      .sink { [weak self] snapshot in self?.apply(snapshot) }
      .store(in: &cancellables)
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
    } else if snapshot.phase == .listening, hadPrevious {
      play(
        StatusIcon.arrivalPulse(for: snapshot.owner),
        settlingOn: StatusIcon.image(for: .listening, owner: snapshot.owner)
      )
    } else {
      button.image = StatusIcon.image(for: snapshot.phase, owner: snapshot.owner)
    }
  }

  /// Cycles 18pt frames at 20 fps — cheap enough to only run while a state is
  /// actually changing, and it stops on the frame that settles the state.
  private func play(_ frames: [NSImage], settlingOn settle: NSImage?) {
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
            self.stopAnimation()
          } else {
            self.frameIndex = 0
            button.image = frames[0]
          }
          return
        }
        button.image = frames[self.frameIndex]
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    animationTimer = timer
  }

  /// The transitional glyph is a `CAShapeLayer` of our own, not the button's
  /// layer: AppKit anchors a view's own layer at `(0, 0)`, so rotating it turns
  /// the icon around the button's corner and throws it out of the menu bar. A
  /// sublayer we create is anchored at its centre, which is what "spin in place"
  /// needs.
  private func startSpin(on button: NSStatusBarButton, clockwise: Bool, secondsPerTurn: Double) {
    stopSpinShape()
    button.wantsLayer = true
    guard let host = button.layer else { return }

    let side: CGFloat = 18
    let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let center = host.bounds.isEmpty
      ? CGPoint(x: side / 2, y: side / 2)
      : CGPoint(x: host.bounds.midX, y: host.bounds.midY)

    let shape = CAShapeLayer()
    shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
    shape.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    shape.position = center
    shape.path = StatusIcon.spinArcPath(side: side)
    shape.fillColor = nil
    shape.strokeColor = (isDark ? NSColor.white : NSColor.black).cgColor
    shape.lineWidth = 1.6
    shape.lineCap = .round
    host.addSublayer(shape)
    spinShape = shape

    // The template image would draw a second, static glyph underneath.
    button.image = nil

    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0
    spin.toValue = (clockwise ? -1.0 : 1.0) * 2 * Double.pi
    spin.duration = secondsPerTurn
    spin.repeatCount = .infinity
    spin.isRemovedOnCompletion = false
    shape.add(spin, forKey: "dsh.spin")
  }

  private func stopSpinShape() {
    spinShape?.removeFromSuperlayer()
    spinShape = nil
  }

  private func stopAnimation() {
    animationTimer?.invalidate()
    animationTimer = nil
    stopSpinShape()
  }

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
    // user can never put the panel into a state the process is not in.
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
