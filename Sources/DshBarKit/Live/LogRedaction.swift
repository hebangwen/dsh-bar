import Foundation

/// The launch token is a bearer credential for dsh's `/api` fence: whoever has the
/// URL has the server. It arrives on stdout as part of the launch line, so three
/// places could keep it longer than the run that printed it — the log file on disk,
/// the four lines the panel shows, and the handoff note left for the next launch.
/// All three pass through here.
///
/// Deliberately not a regex: the value is read with an explicit character set, so a
/// URL followed by punctuation (`…?token=abc).`) cannot swallow the punctuation into
/// the redacted span, and a word that merely ends in `token` (`mytoken=`) is left
/// alone.
public enum LogRedaction {
  /// What replaces the value. One glyph, so a redacted line still reads as a URL.
  public static let placeholder = "…"

  /// The query keys that carry a credential.
  public static let secretKeys = ["token"]

  private static let key = "token"

  /// Characters a token can be made of. `)` `,` `;` `"` `'` `<` `>` and `&` are
  /// not in the set, which is what keeps prose around a pasted URL intact.
  private static let valueCharacters = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/=%"
  )

  /// Replace every `token=<value>` in a line. Idempotent: a redacted line stays as
  /// it is, so passing a line through twice cannot grow it.
  public static func redact(_ text: String) -> String {
    guard text.range(of: key, options: .caseInsensitive) != nil else { return text }
    var output = ""
    output.reserveCapacity(text.count)
    var index = text.startIndex
    while index < text.endIndex {
      if let valueStart = valueStart(after: index, in: text) {
        let before = index == text.startIndex ? nil : text[text.index(before: index)]
        // `mytoken=` is not our key; a key at the start of a line or after a
        // delimiter (`?`, `&`, space, quote, bracket) is.
        let isKey = before.map { !($0.isLetter || $0.isNumber || $0 == "_") } ?? true
        if isKey {
          var cursor = valueStart
          while cursor < text.endIndex, valueCharacters.contains(text[cursor]) {
            cursor = text.index(after: cursor)
          }
          if cursor > valueStart {
            output.append(contentsOf: text[index..<valueStart])
            output.append(placeholder)
            index = cursor
            continue
          }
        }
      }
      output.append(text[index])
      index = text.index(after: index)
    }
    return output
  }

  /// The URL with the token value replaced. Used for anything that is stored or
  /// shown: the panel's log tail, the log file, the handoff note.
  ///
  /// Plain text surgery, not `URLComponents`: rebuilding the URL would
  /// percent-encode the placeholder into `%E2%80%A6`, which is uglier than the
  /// value it replaced and would make a redacted line look like a different bug.
  public static func redactedURL(_ url: String) -> String {
    redact(url)
  }

  /// The same URL with the credential removed entirely — what "copy link without
  /// the token" hands out. Other query parameters survive: they may carry routing
  /// the reader needs.
  public static func urlWithoutToken(_ url: String) -> String? {
    guard var components = URLComponents(string: url) else { return nil }
    if let items = components.queryItems {
      let kept = items.filter { !isSecret($0.name) }
      components.queryItems = kept.isEmpty ? nil : kept
    }
    return components.string
  }

  /// True when the URL carries something worth not handing out.
  public static func carriesToken(_ url: String) -> Bool {
    guard let components = URLComponents(string: url), let items = components.queryItems else {
      return redact(url) != url
    }
    return items.contains { isSecret($0.name) && !($0.value ?? "").isEmpty }
  }

  public static func isSecret(_ name: String) -> Bool {
    secretKeys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
  }

  /// Where the value begins when `token=` starts at `index`.
  private static func valueStart(after index: String.Index, in text: String) -> String.Index? {
    let end = text.index(index, offsetBy: key.count + 1, limitedBy: text.endIndex)
    guard let end, end <= text.endIndex else { return nil }
    let candidate = text[index..<end]
    guard candidate.lowercased() == "\(key)=" else { return nil }
    return end
  }
}
