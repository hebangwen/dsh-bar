import Darwin
import Foundation

/// What is on a port, decided by listening to it rather than by guessing.
public enum PortState: Sendable, Equatable {
  /// Nothing is bound: the app may start dsh here.
  case free
  /// A dsh Web server answered with its unauthenticated fence, so it belongs to
  /// something this app did not start.
  case dsh
  /// Something else is on the port: start must fail with `portInUse`.
  case other
}

/// A plain `connect()` plus one unauthenticated `GET /`.
///
/// `dsh web` answers every unauthenticated root request with the same 401 body,
/// which is a stable fingerprint; anything else on the port gets `.other`
/// instead of being reported as a dsh the app could stop.
public enum PortProbe {
  public static let fingerprint = "dsh web authentication required"

  public static func classify(statusCode: Int, bodyHead: String) -> PortState {
    let body = bodyHead.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix(fingerprint) { return .dsh }
    if statusCode == 401, body.lowercased().contains("dsh web") { return .dsh }
    return .other
  }

  /// Split a raw HTTP response into status code and body. Lenient: the app only
  /// needs the first line and the first characters after the header block.
  public static func splitResponse(_ text: String) -> (status: Int, body: String) {
    let separator = text.range(of: "\r\n\r\n") ?? text.range(of: "\n\n")
    let head = separator.map { String(text[text.startIndex..<$0.lowerBound]) } ?? text
    let body = separator.map { String(text[$0.upperBound...]) } ?? ""
    let statusLine = head.split(separator: "\r\n", maxSplits: 1).first
      ?? head.split(separator: "\n", maxSplits: 1).first
      ?? Substring(head)
    let parts = statusLine.split(separator: " ")
    let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    return (status, body)
  }

  /// Blocking probe on the calling thread; call it off the main actor.
  public static func probe(
    host: String = "127.0.0.1",
    port: Int,
    timeout: TimeInterval = 0.3
  ) -> PortState {
    guard (1...65535).contains(port) else { return .free }
    guard host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0" else {
      // Only loopback is probed; a remote host is not this app's business.
      return .free
    }

    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return .free }
    defer { close(descriptor) }

    let flags = fcntl(descriptor, F_GETFL, 0)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { return .free }

    let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        connect(descriptor, socketAddress, length)
      }
    }

    if connected != 0 {
      guard errno == EINPROGRESS else { return .free }  // ECONNREFUSED et al.
      guard wait(descriptor, events: Int16(POLLOUT), timeout: timeout) else { return .free }
      var error: Int32 = 0
      var errorLength = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &errorLength) == 0,
            error == 0
      else { return .free }
    }

    let request = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nUser-Agent: dsh-bar\r\n\r\n"
    let bytes = Array(request.utf8)
    var sent = 0
    while sent < bytes.count {
      let written = bytes.withUnsafeBytes { buffer in
        send(descriptor, buffer.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
      }
      if written <= 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK {
          guard wait(descriptor, events: Int16(POLLOUT), timeout: timeout) else { return .other }
          continue
        }
        return .other
      }
      sent += written
    }

    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    let deadline = Date().addingTimeInterval(timeout)
    while received.count < 1024, Date() < deadline {
      guard wait(descriptor, events: Int16(POLLIN), timeout: max(0.01, deadline.timeIntervalSinceNow)) else {
        break
      }
      let count = recv(descriptor, &buffer, buffer.count, 0)
      if count <= 0 { break }
      received.append(contentsOf: buffer[0..<count])
      if received.count >= 1024 { break }
    }

    guard let text = String(data: received, encoding: .utf8), !text.isEmpty else {
      return .other
    }
    let response = splitResponse(text)
    return classify(statusCode: response.status, bodyHead: response.body)
  }

  /// `poll` returning > 0 means the socket is ready for one of `events`; a
  /// timeout or an error both mean "no answer", which callers translate.
  private static func wait(_ descriptor: Int32, events: Int16, timeout: TimeInterval) -> Bool {
    var entry = pollfd(fd: descriptor, events: events, revents: 0)
    let milliseconds = Int32(max(1, min(timeout, 5) * 1000))
    let ready = poll(&entry, 1, milliseconds)
    return ready > 0 && (entry.revents & events) != 0
  }
}
