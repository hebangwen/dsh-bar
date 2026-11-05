import Foundation

/// Whether the app may read one of the folders macOS protects with TCC.
///
/// `~/Documents`, `~/Desktop` and `~/Downloads` are guarded per app identity, not
/// per path: a process that has never been granted one gets `EPERM` from `opendir`
/// and macOS puts up a "wants to access your Documents folder" sheet. An app that
/// is ad-hoc signed and rebuilt for every change gets a new code identity each
/// time, so that sheet comes back after every build — which is exactly the
/// "confirm it again on every launch" this type exists to end.
public enum FolderAccessState: String, Sendable, Equatable, CaseIterable {
  /// Nothing has been stored yet: the app has never asked.
  case notRequested
  /// The folder lists without an error.
  case granted
  /// The folder exists but the read was refused (TCC, or a real POSIX denial).
  case denied
  /// The path does not exist (or is not a directory).
  case missing

  public var isGranted: Bool { self == .granted }

  /// Whether the system can still be convinced from inside the app. Once TCC has
  /// recorded a denial, only System Settings can flip it; a fresh prompt needs the
  /// user's own selection, which is what `.notRequested` and `.denied` both offer.
  public var needsUserChoice: Bool { self != .granted }
}

/// One read-only look at a folder.
public struct FolderProbe: Sendable, Equatable {
  public let state: FolderAccessState
  public let entryCount: Int
  public let detail: String?

  public init(state: FolderAccessState, entryCount: Int = 0, detail: String? = nil) {
    self.state = state
    self.entryCount = entryCount
    self.detail = detail
  }
}

/// Everything the settings row needs, taken as one snapshot so the view never
/// races a probe.
public struct FolderAccessSnapshot: Sendable, Equatable {
  public let folder: URL
  public let displayPath: String
  public let state: FolderAccessState
  public let entryCount: Int
  public let detail: String?
  /// A bookmark is stored, so a grant given once survives relaunches.
  public let hasBookmark: Bool
  /// The stored bookmark handed back a security-scoped URL this process holds.
  public let scoped: Bool
  public let probedAt: Date

  public init(
    folder: URL,
    displayPath: String,
    state: FolderAccessState,
    entryCount: Int,
    detail: String?,
    hasBookmark: Bool,
    scoped: Bool,
    probedAt: Date = Date()
  ) {
    self.folder = folder
    self.displayPath = displayPath
    self.state = state
    self.entryCount = entryCount
    self.detail = detail
    self.hasBookmark = hasBookmark
    self.scoped = scoped
    self.probedAt = probedAt
  }

  public var isGranted: Bool { state == .granted }
}

/// Reads, remembers and re-acquires permission for one folder.
///
/// Two layers, because each one covers a different failure:
///
/// 1. **A security-scoped bookmark** in `UserDefaults` — created from the URL the
///    user picked in an open panel, resolved on every launch and consumed with
///    `startAccessingSecurityScopedResource()`. This is the "given once, works
///    later" half.
/// 2. **A live probe** — `contentsOfDirectory` on the folder. TCC is the actual
///    gatekeeper and only it knows the truth, so what the app reports is what a
///    read returns right now, never what the bookmark file claims.
///
/// Deliberately not `@MainActor`: a probe touches the filesystem and callers may
/// be anywhere, so the type locks instead.
public final class FolderAccessStore: @unchecked Sendable {
  public enum Key {
    public static let bookmark = "documentsFolderBookmark"
    public static let path = "documentsFolderPath"
  }

  /// What the app points at. `DSHBAR_DOCUMENTS_FOLDER` overrides it for design
  /// review: the row's "not requested" and "denied" states are otherwise hard to
  /// look at on a machine that already holds the grant.
  public static let folderOverrideKey = "DSHBAR_DOCUMENTS_FOLDER"

  /// The folder dsh's default workspace lives in.
  public static var defaultDocumentsFolder: URL {
    if let override = ProcessInfo.processInfo.environment[folderOverrideKey], !override.isEmpty {
      return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
    }
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
  }

  private let defaults: UserDefaults
  private let folder: URL
  private let lock = NSLock()
  private var scopedURL: URL?
  private var isAccessing = false

  public init(defaults: UserDefaults = .standard, folder: URL? = nil) {
    self.defaults = defaults
    self.folder = folder ?? Self.defaultDocumentsFolder
  }

  public var hasBookmark: Bool {
    lock.lock()
    defer { lock.unlock() }
    return defaults.data(forKey: Key.bookmark) != nil
  }

  /// The folder this store is about — what `~/Documents` resolves to.
  public var target: URL { folder }

  /// `~/Documents` rather than the full home path: the row has one line.
  public static func shortPath(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
    let path = url.standardizedFileURL.path
    let homePath = home.standardizedFileURL.path
    if path == homePath { return "~" }
    if path.hasPrefix(homePath + "/") {
      return "~" + path.dropFirst(homePath.count)
    }
    return path
  }

  // MARK: - Probing

  /// The only honest check: try the read and report what happened.
  public static func probe(_ url: URL) -> FolderProbe {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return FolderProbe(state: .missing, detail: "no such folder")
    }
    guard isDirectory.boolValue else {
      return FolderProbe(state: .missing, detail: "not a folder")
    }
    do {
      let entries = try manager.contentsOfDirectory(atPath: url.path)
      return FolderProbe(state: .granted, entryCount: entries.count, detail: nil)
    } catch {
      let nsError = error as NSError
      return FolderProbe(state: .denied, detail: Self.describe(nsError))
    }
  }

  /// `NSCocoaErrorDomain 257` is the TCC refusal (`NSFileReadNoPermissionError`);
  /// spelling it out beats the generic localized string, which says the same thing
  /// for a chmod denial.
  private static func describe(_ error: NSError) -> String {
    let code = error.code
    if error.domain == NSCocoaErrorDomain, code == NSFileReadNoPermissionError {
      return "NSCocoaErrorDomain \(code) · no read permission (TCC)"
    }
    let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
    let suffix = underlying.map { " · \($0.domain) \($0.code)" } ?? ""
    return "\(error.domain) \(code)\(suffix)"
  }

  /// - Parameter shouldProbe: `false` reports the state without reading the folder.
  ///   That matters: a read from a process that has never been granted the folder is
  ///   exactly what *raises* the system sheet, so the launch path stays hands-off
  ///   until a bookmark exists and asks in its own window instead.
  public func snapshot(probe shouldProbe: Bool = true) -> FolderAccessSnapshot {
    // Probe what was granted when something was: a user who picked a subfolder
    // must see the truth about that subfolder, not about the folder it sits in.
    let stored = storedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let subject = stored ?? folder
    let probe = (shouldProbe || hasStoredBookmark)
      ? Self.probe(subject)
      : FolderProbe(state: .notRequested, detail: "not asked yet")
    // A refusal with no stored bookmark was never asked for, so it is reported as
    // "never asked" rather than as a denial the user does not remember giving.
    let state: FolderAccessState
    switch probe.state {
    case .granted, .missing: state = probe.state
    case .denied, .notRequested: state = hasStoredBookmark ? probe.state : .notRequested
    }
    return FolderAccessSnapshot(
      folder: subject,
      displayPath: Self.shortPath(subject),
      state: state,
      entryCount: probe.entryCount,
      detail: probe.detail,
      hasBookmark: hasStoredBookmark,
      scoped: isScoped
    )
  }

  private var hasStoredBookmark: Bool {
    lock.lock()
    defer { lock.unlock() }
    return defaults.data(forKey: Key.bookmark) != nil
  }

  private var isScoped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isAccessing
  }

  // MARK: - Granting

  /// Remembers the URL the user picked and starts reading through it.
  ///
  /// The URL must come from a user selection (`NSOpenPanel`), which is what tells
  /// TCC that the access was intended. Called with a hand-built path it still
  /// stores a bookmark, but nothing has granted the read and the probe will say so.
  @discardableResult
  public func grant(_ url: URL) throws -> FolderAccessSnapshot {
    let data: Data
    do {
      data = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } catch {
      // A non-sandboxed app can be refused `.withSecurityScope`; a plain bookmark
      // still resolves, and TCC — not the bookmark flavour — decides the read.
      data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    lock.lock()
    defaults.set(data, forKey: Key.bookmark)
    defaults.set(url.path, forKey: Key.path)
    lock.unlock()
    _ = startAccessing()
    return snapshot()
  }

  /// Resolves the stored bookmark and consumes its scope. Returns `true` when the
  /// folder can actually be read afterwards.
  ///
  /// Called at launch and again before every spawn: the child inherits the app's
  /// responsible-process identity, so holding the grant here is what lets the
  /// spawned `dsh` read the workspace without a second prompt.
  @discardableResult
  public func startAccessing() -> Bool {
    lock.lock()
    if isAccessing, let scopedURL {
      lock.unlock()
      return Self.probe(scopedURL).state == .granted
    }
    guard let data = defaults.data(forKey: Key.bookmark) else {
      lock.unlock()
      // Nothing stored: there is no scope to acquire, and probing here would raise
      // the very sheet this feature exists to avoid.
      return false
    }
    lock.unlock()

    guard let (url, stale) = Self.resolve(data) else {
      return false
    }
    // `false` from this call is normal outside the sandbox: no extension is
    // consumed, and TCC alone decides. Keep the URL either way and let the probe
    // speak.
    let consumed = url.startAccessingSecurityScopedResource()
    lock.lock()
    scopedURL = url
    isAccessing = consumed
    if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
      defaults.set(fresh, forKey: Key.bookmark)
    }
    lock.unlock()
    return Self.probe(url).state == .granted
  }

  public func stopAccessing() {
    lock.lock()
    let url = scopedURL
    scopedURL = nil
    isAccessing = false
    lock.unlock()
    url?.stopAccessingSecurityScopedResource()
  }

  /// Forgets the grant. Screen Recording-style permissions cannot be reset from
  /// inside an app, but the bookmark is ours to drop, and dropping it is what
  /// makes the next launch ask again instead of failing silently.
  public func revoke() {
    stopAccessing()
    lock.lock()
    defaults.removeObject(forKey: Key.bookmark)
    defaults.removeObject(forKey: Key.path)
    lock.unlock()
  }

  /// The URL as it is stored, for a settings row that wants to show it.
  public var storedPath: String? {
    lock.lock()
    defer { lock.unlock() }
    return defaults.string(forKey: Key.path)
  }

  // MARK: - Bookmarks

  private static func resolve(_ data: Data) -> (URL, Bool)? {
    var stale = false
    if let url = try? URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    ) {
      return (url, stale)
    }
    if let url = try? URL(
      resolvingBookmarkData: data,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    ) {
      return (url, stale)
    }
    return nil
  }
}

/// The one store the app uses. `Settings` grants through it, `LiveBackend` re-reads
/// it before every spawn, and the check tool gets its own instance with a throwaway
/// defaults domain.
public enum DocumentsAccess {
  public static let store = FolderAccessStore()

  /// `~/Documents/deepseek-harness` is dsh's default workspace; named here so the
  /// log line and the settings note can say why the folder is wanted at all.
  public static var defaultWorkspaceURL: URL {
    store.target.appendingPathComponent("deepseek-harness/default-workspace", isDirectory: true)
  }
}
