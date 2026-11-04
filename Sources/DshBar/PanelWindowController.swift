import AppKit
import Combine
import DshBarKit
import SwiftUI

/// A borderless panel that can still become key, so buttons, Escape and
/// VoiceOver behave like a real window while the chrome stays out of the way.
final class PanelWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelWindowController: NSObject {
  private let model: HarnessModel
  private let handler: (PanelAction) -> Void
  private let window: PanelWindow
  private let hosting: NSHostingView<PanelRoot>
  private var cancellables = Set<AnyCancellable>()
  private weak var anchorButton: NSStatusBarButton?
  private(set) var isVisible = false
  private var keyMonitor: Any?
  private var clickMonitor: Any?

  init(model: HarnessModel, handler: @escaping (PanelAction) -> Void) {
    self.model = model
    self.handler = handler
    hosting = NSHostingView(rootView: PanelRoot(model: model, handler: handler))
    window = PanelWindow(
      contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 320),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    super.init()

    window.contentView = hosting
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .statusBar
    window.isMovable = false
    window.hidesOnDeactivate = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

    model.objectWillChange
      .sink { [weak self] _ in
        DispatchQueue.main.async { self?.resync(animated: true) }
      }
      .store(in: &cancellables)

    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.isVisible, event.keyCode == 53 else { return event }
      self.hide()
      return nil
    }

    // Clicking anywhere outside the app closes the panel. Events inside our own
    // app (including the status item) never reach a global monitor, so the
    // toggle keeps working.
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isVisible else { return }
        if !self.window.frame.contains(NSEvent.mouseLocation) {
          self.hide()
        }
      }
    }
  }

  deinit {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
  }

  func toggle(relativeTo button: NSStatusBarButton?) {
    if isVisible { hide() } else { show(relativeTo: button) }
  }

  func show(relativeTo button: NSStatusBarButton?) {
    anchorButton = button
    isVisible = true
    resync(animated: false)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)

    // `DSHBAR_SNAPSHOT_WINDOW=<path>` writes exactly what the window draws, so
    // layout and clipping can be checked without a screen recording grant.
    // `DSHBAR_SNAPSHOT_DELAY` waits before the shot, for states that settle late.
    if let path = ProcessInfo.processInfo.environment["DSHBAR_SNAPSHOT_WINDOW"] {
      let delay = Double(ProcessInfo.processInfo.environment["DSHBAR_SNAPSHOT_DELAY"] ?? "") ?? 0.4
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, let view = self.window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
          view.cacheDisplay(in: view.bounds, to: rep)
          if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            NSLog("DBG window png %@", "\(path) \(NSStringFromRect(view.bounds))")
          }
        }
      }
    }
  }

  /// `returnFocus` hands the front app back after the panel closes; callers that
  /// immediately open another window of ours pass `false`.
  func hide(returnFocus: Bool = true) {
    guard isVisible else { return }
    window.orderOut(nil)
    isVisible = false
    if returnFocus { NSApp.hide(nil) }
  }

  /// Tracks the SwiftUI content height and keeps the panel pinned under the
  /// status item, clamped to the screen.
  private func resync(animated: Bool) {
    // The uptime tick publishes every second; laying out a hidden window for it
    // is wasted work.
    guard isVisible else { return }
    hosting.layoutSubtreeIfNeeded()
    let height = max(120, ceil(hosting.fittingSize.height))
    let size = NSSize(width: Metrics.panelWidth, height: height)
    let target = targetFrame(for: size)
    hosting.frame = NSRect(origin: .zero, size: size)
    guard window.frame != target else { return }
    if animated, isVisible {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().setFrame(target, display: true)
      }
    } else {
      window.setFrame(target, display: true)
    }
  }

  private func targetFrame(for size: NSSize) -> NSRect {
    guard
      let button = anchorButton,
      let buttonWindow = button.window
    else {
      return NSRect(origin: window.frame.origin, size: size)
    }
    let rectInWindow = button.convert(button.bounds, to: nil)
    let rectOnScreen = buttonWindow.convertToScreen(rectInWindow)
    // The status bar window sits above the screen, so its frame is useless for
    // vertical placement; the menu bar edge is the reliable anchor.
    let screen = buttonWindow.screen ?? NSScreen.screens.first
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    var x = rectOnScreen.midX - size.width / 2
    let y = visible.maxY - 5 - size.height
    x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
    return NSRect(x: x, y: y, width: size.width, height: size.height)
  }
}

/// The panel root: the only place the value-driven panel and the live model meet.
struct PanelRoot: View {
  @ObservedObject var model: HarnessModel
  var handler: (PanelAction) -> Void

  var body: some View {
    PanelView(
      snapshot: model.snapshot,
      copy: model.copy,
      palette: Palette.forScheme(model.effectiveScheme),
      actions: handler
    )
    .fixedSize(horizontal: false, vertical: true)
    .environment(\.colorScheme, model.effectiveScheme)
  }
}
