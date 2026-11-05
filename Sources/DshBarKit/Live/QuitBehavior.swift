import Foundation

/// What quitting the app does to a server it started.
///
/// The default is the safe one: a process the app owns should not outlive it,
/// because the panel is the only place that knows the launch token. Keeping it
/// running is a real workflow though — the browser session survives a login-item
/// restart — so it is offered, and choosing it writes a handoff record instead of
/// pretending nothing happened.
public enum QuitBehavior: String, Sendable, Equatable, CaseIterable {
  /// Stop the managed server before the app exits. The 0.3.0 behaviour.
  case stopManaged
  /// Leave it running and remember pid / port so the next launch can recognise it.
  case keepRunning
  /// Put the question on screen at quit time, with a "remember this" checkbox.
  case ask

  public static func label(_ behavior: QuitBehavior, language: UILanguage) -> String {
    switch behavior {
    case .stopManaged:
      return language == .zhHans ? "停止服务器" : "Stop the server"
    case .keepRunning:
      return language == .zhHans ? "保持运行" : "Keep it running"
    case .ask:
      return language == .zhHans ? "每次询问" : "Ask every time"
    }
  }
}
