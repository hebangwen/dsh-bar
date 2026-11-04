import Foundation

/// Which pipe a captured line came from. dsh writes the launch URL to stdout and
/// everything else (plugin failures, mobile warnings) to stderr.
public enum LogStream: String, Sendable, Equatable, CaseIterable {
  case out
  case err
}

/// A short, fixed-capacity ring of output lines.
///
/// The panel shows four lines; the file on disk keeps everything. Forty is enough
/// to include the launch line after a burst of plugin noise.
public struct LogBuffer: Sendable, Equatable {
  public let capacity: Int
  public private(set) var lines: [LogLine] = []
  private var nextID = 0

  public init(capacity: Int = 40) {
    self.capacity = max(1, capacity)
  }

  public var isEmpty: Bool { lines.isEmpty }

  public mutating func append(
    _ text: String,
    stream: LogStream = .out,
    at date: Date = Date(),
    calendar: Calendar = .current
  ) {
    let capped = text.count > Self.maximumLineLength
      ? String(text.prefix(Self.maximumLineLength)) + "…"
      : text
    let line = LogLine(
      id: nextID,
      time: Self.clock(date, calendar: calendar),
      text: capped,
      emphasized: Self.isEmphasized(capped, stream: stream),
      stream: stream
    )
    nextID += 1
    lines.append(line)
    if lines.count > capacity {
      lines.removeFirst(lines.count - capacity)
    }
  }

  public mutating func reset() {
    lines.removeAll()
    nextID = 0
  }

  /// 8 KB is far beyond anything dsh prints; it exists so a runaway line cannot
  /// grow the buffer without bound.
  public static let maximumLineLength = 8 * 1024

  /// The launch URL, a hard failure, and port contention are what a reader looks
  /// for first, so they get the emphasized treatment in the tail.
  public static func isEmphasized(_ text: String, stream: LogStream = .out) -> Bool {
    if text.hasPrefix(LaunchOutput.prefix) { return true }
    for marker in ["EADDRINUSE", "startup failed", "Error:", "error:", "Cannot", "failed to"] {
      if text.contains(marker) { return true }
    }
    return false
  }

  public static func clock(_ date: Date = Date(), calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
    return String(
      format: "%02d:%02d:%02d",
      parts.hour ?? 0,
      parts.minute ?? 0,
      parts.second ?? 0
    )
  }
}
