import AppKit
import Carbon.HIToolbox
import DshBarKit

/// The live half of the global shortcut: Carbon registration and the event handler.
///
/// `RegisterEventHotKey` is used instead of `NSEvent.addGlobalMonitorForEvents`
/// because a monitor needs Accessibility permission and only observes — it cannot
/// swallow the chord. This one registers a real system hot key, so `⌥⌘D` reaches
/// the app even when nothing is focused.
@MainActor
final class HotKeyCenter {
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private(set) var choice: HotKeyChoice = .off
  private(set) var status: HotKeyStatus = .off

  /// Called on the main thread when the chord is pressed.
  var onTrigger: (() -> Void)?

  /// Install (or uninstall) a binding. Returns what actually happened, so the
  /// settings row can say "taken" rather than showing an enabled shortcut that
  /// does nothing.
  @discardableResult
  func apply(_ next: HotKeyChoice) -> HotKeyStatus {
    unregister()
    choice = next
    guard next.isEnabled, let keyCode = next.keyCode else {
      status = .off
      return .off
    }
    installHandlerIfNeeded()
    var reference: EventHotKeyRef?
    let identifier = EventHotKeyID(signature: HotKeyCenter.signature, id: 1)
    let result = RegisterEventHotKey(
      keyCode,
      next.modifiers,
      identifier,
      GetApplicationEventTarget(),
      0,
      &reference
    )
    guard result == noErr, reference != nil else {
      status = .taken
      return .taken
    }
    hotKeyRef = reference
    status = .active
    return .active
  }

  private func unregister() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    status = .off
  }

  private func installHandlerIfNeeded() {
    HotKeyRouter.shared.action = { [weak self] in self?.onTrigger?() }
    guard handlerRef == nil else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    InstallEventHandler(
      GetApplicationEventTarget(),
      hotKeyCallback,
      1,
      &eventType,
      nil,
      &handlerRef
    )
  }

  /// `'DSHB'` as a FourCharCode, so a hot key registered by another copy of the
  /// app is recognisable in the event.
  static let signature: OSType = 0x4453_4842
}

/// The C callback cannot capture, so the action lives in one shared box.
private final class HotKeyRouter: @unchecked Sendable {
  static let shared = HotKeyRouter()
  var action: (() -> Void)?
}

private let hotKeyCallback: EventHandlerUPP = { _, _, _ in
  HotKeyRouter.shared.action?()
  return noErr
}
