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
  ///
  /// `host` is the address the server is bound to, which is no longer always
  /// loopback: `--host` can put dsh on one local interface, and probing the wrong
  /// address would report "free" for a port that is serving. Only numeric literals
  /// are probed (dsh refuses host names); anything unparsable is treated as "not
  /// ours to judge" and reported free, the same answer the loopback-only version
  /// gave for a remote host.
  public static func probe(
    host: String = "127.0.0.1",
    port: Int,
    timeout: TimeInterval = 0.3
  ) -> PortState {
    guard (1...65535).contains(port) else { return .free }
    let target = normalizedHost(host)
    guard let address = numericAddress(target, port: port) else { return .free }

    let descriptor = socket(address.family, SOCK_STREAM, address.proto)
    guard descriptor >= 0 else { return .free }
    defer { close(descriptor) }

    let flags = fcntl(descriptor, F_GETFL, 0)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

    let connected = address.withSockAddr { pointer, length in
      connect(descriptor, pointer, length)
    }

    if connected != 0 {
      // Refused means nothing is listening: that is a free port.
      if errno == ECONNREFUSED { return .free }
      guard errno == EINPROGRESS else { return .other }
      // A connect that times out says nothing about the port. Reporting "free"
      // here would let the app spawn onto a port something else is serving.
      guard wait(descriptor, events: Int16(POLLOUT), timeout: timeout) else { return .other }
      var error: Int32 = 0
      var errorLength = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &errorLength) == 0 else {
        return .other
      }
      if error == ECONNREFUSED { return .free }
      guard error == 0 else { return .other }
    }

    let authority = target.contains(":") ? "[\(target)]:\(port)" : "\(target):\(port)"
    let request = "GET / HTTP/1.1\r\nHost: \(authority)\r\nConnection: close\r\nUser-Agent: dsh-bar\r\n\r\n"
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

  /// `localhost` is the one name the app accepts; dsh's own flag takes literals.
  public static func normalizedHost(_ host: String) -> String {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "localhost" { return "127.0.0.1" }
    return trimmed
  }

  /// A resolved numeric address plus the family and protocol a socket needs.
  public struct Address {
    public var family: Int32
    public var proto: Int32
    var storage: sockaddr_storage
    var length: socklen_t

    func withSockAddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
      var copy = storage
      return withUnsafePointer(to: &copy) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
      }
    }
  }

  /// `getaddrinfo` with `AI_NUMERICHOST`: one call covers IPv4 and IPv6 without
  /// the app hand-rolling two sockaddr layouts.
  public static func numericAddress(_ host: String, port: Int) -> Address? {
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let list = result else {
      return nil
    }
    defer { freeaddrinfo(list) }
    guard let first = list.pointee.ai_addr, list.pointee.ai_addrlen > 0 else { return nil }
    var storage = sockaddr_storage()
    let length = min(socklen_t(MemoryLayout<sockaddr_storage>.size), list.pointee.ai_addrlen)
    withUnsafeMutableBytes(of: &storage) { destination in
      let source = UnsafeRawPointer(first)
      destination.copyMemory(from: UnsafeRawBufferPointer(start: source, count: Int(length)))
    }
    return Address(
      family: list.pointee.ai_family,
      proto: list.pointee.ai_protocol,
      storage: storage,
      length: length
    )
  }

  /// `poll` returning > 0 means the socket is ready for one of `events`; a
  /// timeout or an error both mean "no answer", which callers translate.
  private static func wait(_ descriptor: Int32, events: Int16, timeout: TimeInterval) -> Bool {
    var entry = pollfd(fd: descriptor, events: events, revents: 0)
    let milliseconds = Int32(max(1, min(timeout, 5) * 1000))
    let ready = poll(&entry, 1, milliseconds)
    // A refused non-blocking connect reports POLLERR, not POLLOUT; watching only
    // for the requested event would read a refusal as a timeout.
    let interesting = events | Int16(POLLERR) | Int16(POLLHUP)
    return ready > 0 && (entry.revents & interesting) != 0
  }
}
