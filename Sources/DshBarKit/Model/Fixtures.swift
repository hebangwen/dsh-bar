import Foundation

/// The scenes the design has to survive, as data.
///
/// The same fixtures drive the clickable demo in the app and the PNG sheets used
/// for design review, so what is reviewed is what ships.
public enum DemoScene: String, Sendable, CaseIterable {
  case unavailable
  case stopped
  case starting
  case listening
  case listeningExternal
  case stopping
  case failedPort
  case failedExit
  /// M3: a launch refused because the configured workspace is gone.
  case failedWorkspace
  /// M3: a server this app started in an earlier run and kept alive.
  case listeningHandoff

  public var title: String {
    switch self {
    case .unavailable: return "unavailable"
    case .stopped: return "stopped"
    case .starting: return "starting"
    case .listening: return "listening"
    case .listeningExternal: return "listening-external"
    case .stopping: return "stopping"
    case .failedPort: return "failed-port"
    case .failedExit: return "failed-exit"
    case .failedWorkspace: return "failed-workspace"
    case .listeningHandoff: return "listening-handoff"
    }
  }
}

public enum Fixtures {
  /// Real dsh output, as captured: one stdout line carrying the launch URL,
  /// surrounded by stderr noise from plugins. The token line is long on purpose:
  /// the well has to truncate without losing the host.
  public static func log(port: Int = 3080) -> [LogLine] {
    [
      LogLine(id: 0, time: "22:04:09", text: "dsh web: http://127.0.0.1:\(port)/?token={{SECRET_6xmk2p4v}}", emphasized: true),
      LogLine(
        id: 1,
        time: "22:04:10",
        text: "~/Code/manim-lab/bin/manim-serve: line 6: .venv/bin/manim-mcp: No such file or directory",
        stream: .err
      ),
      LogLine(
        id: 2,
        time: "22:04:10",
        text: "(node:50256) [DSH_MOBILE_NETWORK_UNAVAILABLE] Warning: saved LAN interface \"en1\" is not connected",
        stream: .err
      ),
      LogLine(
        id: 3,
        time: "22:04:11",
        text: "(node:50256) [DSH_MOBILE_NETWORK_REFRESH] Warning: could not follow the current LAN address",
        stream: .err
      ),
    ]
  }

  public static func failureLog(port: Int = 3080) -> [LogLine] {
    [
      LogLine(
        id: 0,
        time: "22:04:09",
        text: "dsh: startup failed: 2 required plugins did not activate",
        emphasized: true,
        stream: .err
      ),
      LogLine(id: 1, time: "22:04:09", text: "  webserver (required)", emphasized: true, stream: .err),
      LogLine(
        id: 2,
        time: "22:04:09",
        text: "    Error: listen EADDRINUSE: address already in use 127.0.0.1:\(port)",
        emphasized: true,
        stream: .err
      ),
    ]
  }

  public static func snapshot(for scene: DemoScene, copy: Copy, port: Int = 3080) -> HarnessSnapshot {
    switch scene {
    case .unavailable:
      return HarnessSnapshot(phase: .unavailable, port: port, log: [])
    case .stopped:
      return HarnessSnapshot(
        phase: .stopped,
        port: port,
        lastRun: copy.language == .zhHans ? "2 小时前" : "2h ago",
        log: []
      )
    case .starting:
      return HarnessSnapshot(
        phase: .starting,
        port: port,
        log: Array(log(port: port).prefix(2)),
        busy: true
      )
    case .listening:
      return HarnessSnapshot(
        phase: .listening,
        port: port,
        owner: .dshBar,
        uptime: 761,
        log: log(port: port),
        // A managed server is the one case that holds the idle-sleep assertion, so
        // the reviewed sheet shows the footer marker too.
        awake: true
      )
    case .listeningExternal:
      return HarnessSnapshot(
        phase: .listening,
        port: port,
        owner: .external,
        // dsh bar never saw this process's launch line, so there is no URL to copy.
        hasLaunchURL: false,
        uptime: nil,
        log: []
      )
    case .stopping:
      return HarnessSnapshot(phase: .stopping, port: port, log: [], busy: true)
    case .failedPort:
      return HarnessSnapshot(
        phase: .failed,
        port: port,
        failure: HarnessFailure(kind: .portInUse(port: port)),
        log: failureLog(port: port)
      )
    case .failedExit:
      return HarnessSnapshot(
        phase: .failed,
        port: port,
        failure: HarnessFailure(kind: .exited(code: 1), detail: "Error: listen EADDRINUSE"),
        log: failureLog(port: port)
      )
    case .failedWorkspace:
      return HarnessSnapshot(
        phase: .failed,
        port: port,
        failure: HarnessFailure(
          kind: .workspaceMissing(path: "/Users/you/Code/dsh-lab"),
          detail: "no such folder"
        ),
        log: [
          LogLine(
            id: 0,
            time: "22:04:09",
            text: "dsh bar: not spawning: the working directory is unusable — /Users/you/Code/dsh-lab",
            emphasized: true,
            stream: .err
          )
        ]
      )
    case .listeningHandoff:
      return HarnessSnapshot(
        phase: .listening,
        port: port,
        owner: .external,
        hasLaunchURL: false,
        uptime: nil,
        log: [],
        handoff: true
      )
    }
  }
}
