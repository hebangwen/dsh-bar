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
  /// Settings changed: the backend must not keep a stale copy.
  func update(_ preferences: BarPreferences)
  /// Look at the port and report whether a dsh someone else started is there.
  func refreshExternal()
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
  /// Whether dsh's workspace folder — `~/Documents` — can actually be read, and
  /// whether a bookmark is remembering that grant.
  @Published private(set) var documentsFolder: FolderAccessSnapshot
  @Published private(set) var folderError: String?
  @Published var appearance: AppearanceOverride = .system {
    didSet { applyAppearance() }
  }

  let language: UILanguage
  let demoMode: Bool

  private let backend: HarnessBackend
  private let documentsAccess = DocumentsAccess.store
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

    // Resolve the stored grant before anything can spawn: the child inherits this
    // process's TCC identity, so holding the scope here is what keeps `dsh` from
    // meeting the "wants to access your Documents folder" sheet.
    documentsAccess.startAccessing()
    // Hands off until a bookmark exists: probing an ungranted TCC folder is what
    // makes the system ask, and the app would rather ask in its own window.
    documentsFolder = documentsAccess.snapshot(probe: documentsAccess.hasBookmark)

    if demoMode {
      backend = DemoBackend(language: language, port: preferences.port, profile: preferences.profile)
    } else {
      backend = LiveBackend(language: language, preferences: preferences)
    }

    backend.onSnapshot = { [weak self] snapshot in
      guard let self else { return }
      self.snapshot = snapshot
      self.adoptPort()
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

  /// Every start goes through the folder ask: it is the only moment the grant is
  /// actually needed, and the only moment asking is welcome.
  func start() {
    prepareDocumentsForStart()
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
    // A new port is a new question: is someone else already serving it?
    refreshExternal()
  }

  /// Called before the panel is shown and on a slow timer, so a server started in
  /// a terminal shows up without the user having to press Start.
  func refreshExternal() {
    backend.refreshExternal()
  }

  // MARK: - Folder access

  /// `~/Documents` is TCC-protected; dsh's default workspace lives inside it.
  /// Re-probing is cheap and is the only answer worth showing.
  /// - Parameter probe: `true` for an explicit check (the row's own button); the
  ///   settings window appearing passes `false` so opening settings cannot raise a
  ///   system sheet by itself.
  func refreshDocumentsAccess(probe: Bool = true) {
    documentsFolder = documentsAccess.snapshot(probe: probe)
  }

  /// Asks the system the only way it can be asked: a user selection. The open
  /// panel is what turns a path into a grant, so this deliberately replaces the
  /// launch-time system sheet with one deliberate choice.
  func grantDocumentsFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    // Open the panel *beside* the folder with it preselected: pointing the panel
    // inside ~/Documents would make the user navigate back out to select it.
    let target = documentsAccess.target
    panel.directoryURL = target.deletingLastPathComponent()
    panel.nameFieldStringValue = target.lastPathComponent
    panel.message = copy.grantMessage
    panel.prompt = copy.grantPrompt
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else {
      // Cancelled: nothing changed, and a probe here would only ask the system again.
      refreshDocumentsAccess(probe: false)
      return
    }
    do {
      folderError = nil
      documentsFolder = try documentsAccess.grant(url)
    } catch {
      folderError = "\(error)"
      refreshDocumentsAccess()
    }
  }

  func openPrivacySettings() {
    let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    guard let url = URL(string: pane) else { return }
    NSWorkspace.shared.open(url)
  }

  /// Whether pressing Start is about to ask for the folder. The caller uses it to
  /// get the status panel out of the way before the open panel appears — and it is
  /// deliberately cheap: no probe, because a probe is the thing that raises the
  /// system sheet.
  var owesDocumentsGrant: Bool {
    guard !demoMode else { return false }
    if documentsAccess.hasBookmark {
      // A bookmark that no longer reads (revoked grant, moved folder) is worth
      // re-asking for as well; a healthy one must not produce a panel.
      return documentsFolder.state == .denied
    }
    return documentsFolder.state.needsUserChoice
  }

  /// The folder ask, moved to the moment it is actually needed: the Start click.
  /// Nothing is asked at launch, so opening the app — or leaving it in the menu bar
  /// for a week — never produces a dialog.
  ///
  /// Called before `start()`, and blocks on the panel when it still has to ask.
  /// After it a launch may go ahead either way: the panel row and the log both say
  /// when the grant is still missing.
  func prepareDocumentsForStart() {
    guard !demoMode else { return }
    documentsAccess.startAccessing()
    if documentsAccess.hasBookmark {
      // A stored bookmark may be stale or revoked; that probe is safe (the grant is
      // ours) and it is what keeps a working setup from being asked again.
      documentsFolder = documentsAccess.snapshot()
      if documentsFolder.state == .granted { return }
    }
    grantDocumentsFolder()
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
    // The backend owns its own copy; without this a newly chosen dsh path would
    // be ignored until the next launch.
    backend.update(next)
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
      var environment = LoginShellEnvironment.resolve().values
      // `--version` fails for the same reason a launch would: no node on PATH.
      environment["PATH"] = LoginShellEnvironment.runnablePath(
        forExecutable: path,
        environment: environment
      )
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
    documentsAccess.stopAccessing()
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
  /// `--port 0` lets the OS choose; whatever it chose is now the truth, so the
  /// preference (and the footer) must follow it.
  private func adoptPort() {
    guard snapshot.phase == .listening, snapshot.owner == .dshBar else { return }
    guard snapshot.port != preferences.port else { return }
    var next = preferences
    next.port = snapshot.port
    preferences = next
    next.save()
  }

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
      restartPort = nil
    default:
      break
    }
  }
}
