import AppKit
import Combine
import DshBarKit
import SwiftUI

/// What the panel can talk to: the real controller, or the fixture-driven one
/// used for design review. One protocol keeps the two honest.
@MainActor
protocol HarnessBackend: AnyObject {
  var onSnapshot: ((HarnessSnapshot) -> Void)? { get set }
  /// The authenticated URL dsh printed; nil when there is none to hand out.
  var launchURL: String? { get }
  func start(port: Int, profile: String)
  func stop()
  func cancel()
  func redetect() -> DshLookup
  func preview(_ scene: DemoScene)
  func shutdown()
}

enum AppearanceOverride: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  func label(_ language: UILanguage) -> String {
    switch self {
    case .system: return language == .zhHans ? "跟随系统" : "System"
    case .light: return language == .zhHans ? "浅色" : "Light"
    case .dark: return language == .zhHans ? "深色" : "Dark"
    }
  }
}

/// Where dsh bar keeps what the app writes.
enum DshBarPaths {
  static var logDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/dsh bar", isDirectory: true)
  }

  static var logFile: URL {
    logDirectory.appendingPathComponent("dsh-web.log")
  }
}

/// The one object SwiftUI observes.
///
/// It owns what the panel shows (snapshot, copy, confirmation states) and turns
/// clicks into backend calls. The backend owns every side effect, so the demo
/// build and the live build differ by one line at construction.
@MainActor
final class HarnessModel: ObservableObject {
  @Published private(set) var snapshot: HarnessSnapshot
  @Published private(set) var stopIsConfirming = false
  @Published private(set) var takeOverIsConfirming = false
  @Published private(set) var copied = false
  @Published private(set) var preferences: BarPreferences
  @Published private(set) var detectedPath: String?
  @Published private(set) var detectedSource: DshDetection.Source?
  @Published private(set) var dshVersion: String?
  @Published var appearance: AppearanceOverride = .system {
    didSet { applyAppearance() }
  }

  let language: UILanguage
  let demoMode: Bool

  private let backend: HarnessBackend
  private var confirmReset: DispatchWorkItem?
  private var takeOverReset: DispatchWorkItem?
  private var copyReset: DispatchWorkItem?
  private var restartWhenStopped = false
  /// Set by "Take over": the restarted server must stay on the port the terminal
  /// instance was already using, otherwise the hand-off would move the UI.
  private var restartPort: Int?

  init(demoMode: Bool = ProcessInfo.processInfo.environment["DSHBAR_DEMO"] == "1") {
    let language = UILanguage.matching()
    let preferences = BarPreferences.load()
    self.language = language
    self.demoMode = demoMode
    self.preferences = preferences

    var initial = Fixtures.snapshot(for: .stopped, copy: Copy(language: language), port: preferences.port)
    initial.profile = preferences.profile
    initial.lastRun = nil
    snapshot = initial

    if demoMode {
      backend = DemoBackend(language: language, port: preferences.port, profile: preferences.profile)
    } else {
      backend = LiveBackend(language: language, preferences: preferences)
    }

    backend.onSnapshot = { [weak self] snapshot in
      guard let self else { return }
      self.snapshot = snapshot
      self.didSettle()
    }
    applyAppearance()
  }

  var copy: Copy {
    Copy(language: language)
      .withStopConfirmation(stopIsConfirming)
      .withTakeOverConfirmation(takeOverIsConfirming)
      .withCopyConfirmation(copied)
  }

  var effectiveScheme: ColorScheme {
    switch appearance {
    case .system: return Self.systemScheme
    case .light: return .light
    case .dark: return .dark
    }
  }

  var launchURL: String? { backend.launchURL }

  private static var systemScheme: ColorScheme {
    let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    return match == .darkAqua ? .dark : .light
  }

  func applyAppearance() {
    switch appearance {
    case .system: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    objectWillChange.send()
  }

  // MARK: - Actions

  func start() {
    backend.start(port: preferences.port, profile: preferences.profile)
  }

  func stop() {
    guard snapshot.phase == .listening else { return }
    clearTakeOverConfirmation()
    if snapshot.owner == .external, !stopIsConfirming {
      stopIsConfirming = true
      let reset = DispatchWorkItem { [weak self] in self?.stopIsConfirming = false }
      confirmReset?.cancel()
      confirmReset = reset
      DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: reset)
      return
    }
    clearStopConfirmation()
    backend.stop()
  }

  /// Turns a server someone started in a terminal into one this app owns. It is
  /// destructive — the process has to stop before the app can start its own — so
  /// it takes a second click, and the panel spells out what will be interrupted.
  func takeOver() {
    guard snapshot.phase == .listening, snapshot.owner == .external else { return }
    guard takeOverIsConfirming else {
      takeOverIsConfirming = true
      clearStopConfirmation()
      let reset = DispatchWorkItem { [weak self] in self?.takeOverIsConfirming = false }
      takeOverReset?.cancel()
      takeOverReset = reset
      DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: reset)
      return
    }
    takeOverIsConfirming = false
    restartPort = snapshot.port
    restartWhenStopped = true
    backend.stop()
  }

  func restart() {
    guard snapshot.phase == .listening else { return }
    clearTakeOverConfirmation()
    backend.stop()
    // The backend reports `.stopped` once the process is gone; restart from that
    // event rather than guessing a delay.
    restartWhenStopped = true
  }

  func cancel() {
    backend.cancel()
  }

  func copyLink() {
    guard let url = launchURL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url, forType: .string)
    copied = true
    let reset = DispatchWorkItem { [weak self] in self?.copied = false }
    copyReset?.cancel()
    copyReset = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: reset)
  }

  /// Only meaningful in demo mode: the real controller has no scenes to jump to.
  func jump(to scene: DemoScene) {
    guard demoMode else { return }
    backend.preview(scene)
  }

  func update(port: Int) {
    var next = preferences
    next.port = BarPreferences.normalizePort(port)
    apply(next)
  }

  func update(profile: String) {
    var next = preferences
    next.profile = BarPreferences.normalizeProfile(profile)
    apply(next)
  }

  func chooseBinary(_ path: String?) {
    var next = preferences
    next.binaryPath = BarPreferences.normalizeBinaryPath(path)
    apply(next)
    refreshDetection()
  }

  private func apply(_ next: BarPreferences) {
    preferences = next
    next.save()
    snapshot.port = next.port
    snapshot.profile = next.profile
  }

  // MARK: - Detection

  /// Runs at launch and after any change to the binary path, so Settings can say
  /// what it found without the user pressing anything.
  func refreshDetection() {
    let lookup = backend.redetect()
    switch lookup {
    case .found(let detection):
      detectedPath = detection.path
      detectedSource = detection.source
      readVersion(at: detection.path)
    case .missing:
      detectedPath = nil
      detectedSource = nil
      dshVersion = nil
    }
  }

  private func readVersion(at path: String) {
    dshVersion = nil
    DispatchQueue.global(qos: .utility).async { [weak self] in
      // `dsh` is a `#!/usr/bin/env node` script, so it needs the login shell's
      // PATH even for `--version`.
      let environment = LoginShellEnvironment.resolve().values
      let version = Self.runVersion(path: path, environment: environment)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.detectedPath == path else { return }
          self.dshVersion = version
        }
      }
    }
  }

  nonisolated private static func runVersion(path: String, environment: [String: String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let text = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (text?.isEmpty ?? true) ? nil : text
  }

  // MARK: - Restart plumbing

  func shutdown() {
    backend.shutdown()
  }

  private func clearStopConfirmation() {
    confirmReset?.cancel()
    stopIsConfirming = false
  }

  private func clearTakeOverConfirmation() {
    takeOverReset?.cancel()
    takeOverIsConfirming = false
  }

  /// Called on every snapshot. A restart is two steps — stop, then start from the
  /// settled state — rather than a guessed delay, because the process is the only
  /// thing that knows when the port is free again.
  private func didSettle() {
    guard restartWhenStopped else { return }
    switch snapshot.phase {
    case .stopped:
      restartWhenStopped = false
      let port = restartPort ?? preferences.port
      restartPort = nil
      if port != preferences.port {
        apply(BarPreferences(
          binaryPath: preferences.binaryPath,
          port: port,
          profile: preferences.profile
        ))
      }
      backend.start(port: port, profile: preferences.profile)
    case .failed:
      restartWhenStopped = false
    default:
      break
    }
  }
}
