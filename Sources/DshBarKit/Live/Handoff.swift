import Foundation

/// The note a "keep it running" quit leaves behind.
///
/// Without it, a dsh that survived the app looks exactly like one somebody started
/// in a terminal — which is fine for stopping it, but the panel would be lying
/// about where it came from. The record is only a claim: it is verified against
/// the process table and the port on the next launch, and dropped when anything
/// does not match. Nothing is ever signalled on the strength of this file alone.
public struct HandoffRecord: Codable, Sendable, Equatable {
  public var pid: Int32
  public var port: Int
  public var startedAt: Date
  public var launchURL: String?

  public static let key = "dshBarHandoff"

  public init(pid: Int32, port: Int, startedAt: Date, launchURL: String? = nil) {
    self.pid = pid
    self.port = port
    self.startedAt = startedAt
    self.launchURL = launchURL
  }
}

/// What checking a record concluded.
public enum HandoffVerdict: Sendable, Equatable {
  /// The pid is still this app's dsh and it is the thing on that port.
  case valid
  case noRecord
  /// The process is gone: a normal quit in the terminal, or a crash.
  case pidGone
  /// Something is alive at that pid, but it is not a dsh.
  case notDsh
  /// The pid is a dsh, but the port is served by something else — a restarted
  /// server, or the OS handed the port out again.
  case portMoved

  public var isUsable: Bool { self == .valid }
}

/// One look at the process table and the port, taken as a value so the verdict
/// logic is assertable without spawning anything.
public struct HandoffInspection: Sendable, Equatable {
  public var pidAlive: Bool
  public var command: String?
  public var group: Int32?
  public var portServesDsh: Bool

  public init(pidAlive: Bool, command: String?, group: Int32? = nil, portServesDsh: Bool) {
    self.pidAlive = pidAlive
    self.command = command
    self.group = group
    self.portServesDsh = portServesDsh
  }
}

public enum HandoffStore {
  public static func load(from defaults: UserDefaults = .standard) -> HandoffRecord? {
    guard let data = defaults.data(forKey: HandoffRecord.key) else { return nil }
    return try? JSONDecoder().decode(HandoffRecord.self, from: data)
  }

  /// The note outlives the run, so it is stored without the launch token: nothing
  /// reads the URL back, and a bearer credential at rest is what 0.6.0 removed.
  public static func save(_ record: HandoffRecord, to defaults: UserDefaults = .standard) {
    var safe = record
    safe.launchURL = record.launchURL.map(LogRedaction.redactedURL)
    guard let data = try? JSONEncoder().encode(safe) else { return }
    defaults.set(data, forKey: HandoffRecord.key)
  }

  public static func clear(from defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: HandoffRecord.key)
  }
}

public enum HandoffVerifier {
  /// The whole decision, in one place: a record is only believed when the pid is
  /// alive, its command line is a dsh, and the recorded port answers as one.
  public static func verify(
    _ record: HandoffRecord?,
    inspection: HandoffInspection
  ) -> HandoffVerdict {
    guard record != nil else { return .noRecord }
    guard inspection.pidAlive, let command = inspection.command, !command.isEmpty else {
      return .pidGone
    }
    guard isDsh(command: command, group: inspection.group) else { return .notDsh }
    guard inspection.portServesDsh else { return .portMoved }
    return .valid
  }

  public static func verify(
    _ record: HandoffRecord?,
    inspect: (HandoffRecord) -> HandoffInspection
  ) -> HandoffVerdict {
    guard let record else { return .noRecord }
    return verify(record, inspection: inspect(record))
  }

  /// Same rule the stop path uses: the executable has to be named dsh, not just
  /// mention it, because this answer decides whether the port is ours to describe.
  public static func isDsh(command: String, group: Int32?) -> Bool {
    ExternalInstance.canStop(ExternalInstance.Info(pid: 0, command: command, group: group))
  }

  /// The live inspection: `ps` for the pid, one port probe for the server.
  public static func inspect(_ record: HandoffRecord) -> HandoffInspection {
    guard let info = ExternalInstance.describe(pid: record.pid) else {
      return HandoffInspection(pidAlive: false, command: nil, portServesDsh: false)
    }
    let alive = ExternalInstance.isAlive(info)
    let portState = PortProbe.probe(port: record.port)
    return HandoffInspection(
      pidAlive: alive,
      command: info.command,
      group: info.group,
      portServesDsh: portState == .dsh
    )
  }
}
