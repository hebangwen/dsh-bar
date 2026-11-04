import Darwin
import Foundation

public enum ChildProcessError: Error, Equatable {
  case invalidExecutable(String)
  case pipeFailed(Int32)
  case spawnFailed(Int32)
}

/// One `dsh` child, in its own process group.
///
/// `POSIX_SPAWN_SETSID` matters more than it looks: dsh loads plugins, and those
/// plugins spawn helpers (`manim-mcp`, MCP servers). Killing only the node process
/// leaves them behind, so the app kills the group.
///
/// stdout and stderr are read as lines and delivered on the main queue; the
/// controller owns all state, so nothing here decides anything.
public final class ChildProcess {
  public let pid: pid_t
  public var onLine: ((LogStream, String) -> Void)?
  public var onExit: ((Int32?, Int32?) -> Void)?

  private let queue = DispatchQueue(label: "dev.dsh.bar.child", qos: .userInitiated)
  private var readSources: [LogStream: DispatchSourceRead] = [:]
  private var processSource: DispatchSourceProcess?
  private var pending: [LogStream: Data] = [:]
  private let stateLock = NSLock()
  private var reportedExit = false

  public init(
    executable: String,
    arguments: [String],
    environment: [String: String],
    workingDirectory: String? = nil
  ) throws {
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      throw ChildProcessError.invalidExecutable(executable)
    }

    var stdoutPipe: [Int32] = [0, 0]
    var stderrPipe: [Int32] = [0, 0]
    guard pipe(&stdoutPipe) == 0 else { throw ChildProcessError.pipeFailed(errno) }
    guard pipe(&stderrPipe) == 0 else {
      close(stdoutPipe[0]); close(stdoutPipe[1])
      throw ChildProcessError.pipeFailed(errno)
    }

    // The read ends belong to us; the write ends must not leak into the child's
    // other descriptors, and are closed by the file actions after dup2.
    _ = fcntl(stdoutPipe[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(stderrPipe[0], F_SETFD, FD_CLOEXEC)

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }

    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
    posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
    posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1])
    posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])
    if let workingDirectory {
      _ = workingDirectory.withCString { path in
        posix_spawn_file_actions_addchdir_np(&fileActions, path)
      }
    }

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
    posix_spawnattr_setflags(&attributes, flags)

    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
    argv.append(nil)
    var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)
    defer {
      for pointer in argv where pointer != nil { free(pointer) }
      for pointer in envp where pointer != nil { free(pointer) }
    }

    var child: pid_t = 0
    let result = executable.withCString { path in
      posix_spawn(&child, path, &fileActions, &attributes, argv, envp)
    }

    guard result == 0 else {
      close(stdoutPipe[0]); close(stdoutPipe[1])
      close(stderrPipe[0]); close(stderrPipe[1])
      throw ChildProcessError.spawnFailed(result)
    }

    pid = child
    // The child has its own copy of these; keeping ours open would hold the pipe
    // from ever reaching EOF.
    close(stdoutPipe[1])
    close(stderrPipe[1])

    pending[.out] = Data()
    pending[.err] = Data()
    startReading(stdoutPipe[0], stream: .out)
    startReading(stderrPipe[0], stream: .err)
    watchExit()
  }

  deinit {
    terminate()
  }

  public var isAlive: Bool {
    // `kill` is also this type's SIGKILL method, so name the C function.
    Darwin.kill(pid, 0) == 0 || errno == EPERM
  }

  /// SIGTERM to the whole group: dsh closes its store and its helpers stop.
  public func terminate() {
    killpg(pid, SIGTERM)
  }

  /// SIGKILL to the whole group, for a server that ignored the grace period.
  public func kill() {
    killpg(pid, SIGKILL)
  }

  // MARK: - Reading

  private func startReading(_ descriptor: Int32, stream: LogStream) {
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setEventHandler { [weak self] in
      self?.drain(descriptor, stream: stream)
    }
    source.setCancelHandler {
      close(descriptor)
    }
    readSources[stream] = source
    source.resume()
  }

  private func drain(_ descriptor: Int32, stream: LogStream) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    let count = read(descriptor, &buffer, buffer.count)
    if count > 0 {
      consume(Data(buffer[0..<count]), stream: stream)
      return
    }
    if count < 0, errno == EAGAIN || errno == EINTR { return }
    // EOF: flush the trailing partial line, then stop watching.
    flush(stream)
    readSources[stream]?.cancel()
    readSources[stream] = nil
  }

  private func consume(_ data: Data, stream: LogStream) {
    var buffer = pending[stream] ?? Data()
    buffer.append(data)
    while let index = buffer.firstIndex(of: 0x0A) {
      let lineData = buffer[buffer.startIndex..<index]
      buffer.removeSubrange(buffer.startIndex...index)
      deliver(String(decoding: lineData, as: UTF8.self), stream: stream)
    }
    // A single runaway line must not grow the buffer without bound.
    if buffer.count > LogBuffer.maximumLineLength * 2 {
      deliver(String(decoding: buffer.prefix(LogBuffer.maximumLineLength), as: UTF8.self), stream: stream)
      buffer.removeAll()
    }
    pending[stream] = buffer
  }

  private func flush(_ stream: LogStream) {
    guard let buffer = pending[stream], !buffer.isEmpty else {
      pending[stream] = Data()
      return
    }
    deliver(String(decoding: buffer, as: UTF8.self), stream: stream)
    pending[stream] = Data()
  }

  private func deliver(_ line: String, stream: LogStream) {
    let text = line.hasSuffix("\r") ? String(line.dropLast()) : line
    guard !text.isEmpty else { return }
    guard let handler = onLine else { return }
    DispatchQueue.main.async {
      handler(stream, text)
    }
  }

  // MARK: - Exit

  private func watchExit() {
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
    source.setEventHandler { [weak self] in
      self?.reap()
    }
    processSource = source
    source.resume()
  }

  private func reap() {
    stateLock.lock()
    if reportedExit {
      stateLock.unlock()
      return
    }
    reportedExit = true
    stateLock.unlock()

    var status: Int32 = 0
    let waited = waitpid(pid, &status, WNOHANG)
    let termSignal = status & 0x7f
    let exitedNormally = termSignal == 0
    let code = exitedNormally ? (status >> 8) & 0xff : nil
    let signal = exitedNormally ? nil : termSignal

    processSource?.cancel()
    processSource = nil

    let handler = onExit
    DispatchQueue.main.async {
      handler?(code, waited == self.pid ? signal : nil)
    }
  }
}
