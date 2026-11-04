import SwiftUI

// MARK: - Brand mark

/// A ring with a dot: the same geometry as dsh's own boot spinner, reduced to a
/// mark. Drawn rather than bundled so it stays crisp at 12pt and in the menu bar.
public struct BrandMark: View {
  var palette: Palette
  var diameter: CGFloat
  var lineWidth: CGFloat

  public init(palette: Palette, diameter: CGFloat = 12.5, lineWidth: CGFloat = 1.3) {
    self.palette = palette
    self.diameter = diameter
    self.lineWidth = lineWidth
  }

  public var body: some View {
    ZStack {
      Circle()
        .strokeBorder(palette.ink, lineWidth: lineWidth)
        .frame(width: diameter, height: diameter)
      Circle()
        .fill(palette.ink)
        .frame(width: diameter * 0.3, height: diameter * 0.3)
    }
    .frame(width: diameter, height: diameter)
  }
}

// MARK: - State lamp

/// The one place state shows without words. Shape carries the meaning, so the
/// interface stays readable in monochrome and for colour-blind users; hue is
/// reserved for "changing" and "broken". A lit state gets a bezel ring, the way
/// a real indicator lamp sits in its housing.
public struct RingLamp: View {
  var phase: HarnessPhase
  var owner: ServerOwner
  var palette: Palette

  @State private var pulsing = false

  public init(phase: HarnessPhase, owner: ServerOwner, palette: Palette) {
    self.phase = phase
    self.owner = owner
    self.palette = palette
  }

  private var isStarting: Bool { phase == .starting }

  public var body: some View {
    ZStack {
      switch phase {
      case .unavailable:
        Circle()
          .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 1.7]))
          .foregroundStyle(palette.ink.opacity(0.4))
          .frame(width: 9, height: 9)
      case .stopped:
        Circle()
          .strokeBorder(palette.ink.opacity(0.38), lineWidth: 1.3)
          .frame(width: 8.5, height: 8.5)
      case .starting:
        Circle()
          .strokeBorder(palette.warn.opacity(0.3), lineWidth: 1)
          .frame(width: 13, height: 13)
        Circle()
          .strokeBorder(palette.warn, lineWidth: 1.25)
          .frame(width: 8.5, height: 8.5)
        Circle()
          .fill(palette.warn)
          .frame(width: 3.2, height: 3.2)
          .opacity(pulsing ? 0.2 : 1)
      case .listening:
        Circle()
          .strokeBorder(palette.ink.opacity(0.18), lineWidth: 1)
          .frame(width: 13, height: 13)
        if owner == .external {
          Circle()
            .strokeBorder(palette.ink.opacity(0.55), lineWidth: 1.3)
            .frame(width: 6.5, height: 6.5)
        } else {
          Circle()
            .fill(palette.ink)
            .frame(width: 6.5, height: 6.5)
            // The same breath the menu bar glyph has: while the server is up the
            // dot swells and settles, so "alive" reads without a second glance.
            .phaseAnimator([false, true], trigger: phase) { view, expanded in
              view.scaleEffect(expanded ? 1.3 : 0.82)
            } animation: { _ in
              .easeInOut(duration: 1.15)
            }
        }
      case .stopping:
        Circle()
          .strokeBorder(palette.inkTertiary.opacity(0.35), lineWidth: 1)
          .frame(width: 13, height: 13)
        Circle()
          .strokeBorder(palette.inkTertiary, lineWidth: 1.25)
          .frame(width: 8.5, height: 8.5)
        Circle()
          .fill(palette.inkTertiary)
          .frame(width: 2.8, height: 2.8)
      case .failed:
        Circle()
          .strokeBorder(palette.fail.opacity(0.22), lineWidth: 1)
          .frame(width: 13, height: 13)
        Circle()
          .fill(palette.fail)
          .frame(width: 6.5, height: 6.5)
      }
    }
    .frame(width: 14, height: 14)
    .onAppear {
      guard isStarting else { return }
      withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
        pulsing = true
      }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Engraved rule

/// A rule cut into the plate rather than drawn on it: a dark hairline with a
/// light edge below. Structure, not decoration — it separates the readout from
/// the controls exactly where the reading stops and the acting starts.
public struct EngravedRule: View {
  var palette: Palette

  public init(palette: Palette) {
    self.palette = palette
  }

  public var body: some View {
    VStack(spacing: 0) {
      Rectangle().fill(palette.rule).frame(height: 1)
      Rectangle().fill(palette.ruleGlow).frame(height: 1)
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Buttons

public struct PrimaryActionStyle: ButtonStyle {
  var palette: Palette
  var isEnabled: Bool

  public init(palette: Palette, isEnabled: Bool = true) {
    self.palette = palette
    self.isEnabled = isEnabled
  }

  public func makeBody(configuration: Configuration) -> Core {
    Core(configuration: configuration, palette: palette, isEnabled: isEnabled)
  }

  public struct Core: View {
    public let configuration: Configuration
    public let palette: Palette
    public let isEnabled: Bool
    @State private var hovering = false

    public init(configuration: Configuration, palette: Palette, isEnabled: Bool) {
      self.configuration = configuration
      self.palette = palette
      self.isEnabled = isEnabled
    }

    public var body: some View {
      configuration.label
        .font(Typography.button)
        .foregroundStyle(palette.plate)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.actionHeight)
        .background(
          RoundedRectangle(cornerRadius: Metrics.actionRadius, style: .continuous)
            .fill(palette.ink.opacity(isEnabled ? (hovering ? 0.88 : 1) : 0.26))
        )
        .contentShape(RoundedRectangle(cornerRadius: Metrics.actionRadius, style: .continuous))
        .onHover { hovering = $0 && isEnabled }
        .opacity(configuration.isPressed && isEnabled ? 0.82 : 1)
    }
  }
}

public struct OutlineActionStyle: ButtonStyle {
  var palette: Palette

  public init(palette: Palette) {
    self.palette = palette
  }

  public func makeBody(configuration: Configuration) -> Core {
    Core(configuration: configuration, palette: palette)
  }

  public struct Core: View {
    public let configuration: Configuration
    public let palette: Palette
    @State private var hovering = false

    public init(configuration: Configuration, palette: Palette) {
      self.configuration = configuration
      self.palette = palette
    }

    public var body: some View {
      configuration.label
        .font(Typography.button)
        .foregroundStyle(palette.ink)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.actionHeight)
        .background(
          RoundedRectangle(cornerRadius: Metrics.actionRadius, style: .continuous)
            .fill(hovering ? palette.ink.opacity(0.06) : .clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: Metrics.actionRadius, style: .continuous)
            .strokeBorder(palette.ink.opacity(0.24), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Metrics.actionRadius, style: .continuous))
        .onHover { hovering = $0 }
        .opacity(configuration.isPressed ? 0.7 : 1)
    }
  }
}

public struct TextActionStyle: ButtonStyle {
  var palette: Palette

  public init(palette: Palette) {
    self.palette = palette
  }

  public func makeBody(configuration: Configuration) -> Core {
    Core(configuration: configuration, palette: palette)
  }

  public struct Core: View {
    public let configuration: Configuration
    public let palette: Palette
    @State private var hovering = false

    public init(configuration: Configuration, palette: Palette) {
      self.configuration = configuration
      self.palette = palette
    }

    public var body: some View {
      configuration.label
        .font(Typography.button)
        .foregroundStyle(hovering ? palette.ink : palette.inkSecondary)
        .padding(.horizontal, 1)
        .frame(height: Metrics.tertiaryHeight)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .opacity(configuration.isPressed ? 0.6 : 1)
    }
  }
}

// MARK: - Log tail

/// Output is printed on the plate, not boxed again: the panel already has one
/// recessed surface (the readout band) and a second one would compete with it.
public struct LogTail: View {
  var lines: [LogLine]
  var copy: Copy
  var palette: Palette
  var maxLines: Int
  var onOpenLog: () -> Void

  public init(
    lines: [LogLine],
    copy: Copy,
    palette: Palette,
    maxLines: Int = 4,
    onOpenLog: @escaping () -> Void = {}
  ) {
    self.lines = lines
    self.copy = copy
    self.palette = palette
    self.maxLines = maxLines
    self.onOpenLog = onOpenLog
  }

  /// The last few lines, but never at the cost of the one line worth reading.
  /// A real dsh keeps warning about mobile networking after it is ready, and four
  /// lines of that would push the launch URL out of view within seconds.
  private var visible: [LogLine] {
    let tail = Array(lines.suffix(maxLines))
    guard !tail.contains(where: \.emphasized),
          let latest = lines.last(where: \.emphasized)
    else { return tail }
    return [latest] + Array(tail.dropFirst())
  }

  private var overflows: Bool { lines.count > maxLines }

  public var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(copy.output)
          .font(Typography.label)
          .foregroundStyle(palette.inkTertiary)
        Spacer(minLength: 8)
        Button(action: onOpenLog) {
          Text(copy.openLog)
            .font(Typography.label)
            .foregroundStyle(palette.inkTertiary)
        }
        .buttonStyle(.plain)
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(visible) { line in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time)
              .foregroundStyle(palette.inkTertiary.opacity(0.85))
            Text(line.text)
              .foregroundStyle(line.emphasized ? palette.ink : palette.inkSecondary)
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer(minLength: 0)
          }
          .font(Typography.log)
          .frame(height: Metrics.logLineHeight, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .mask(
        LinearGradient(
          stops: overflows
            ? [
              .init(color: .clear, location: 0),
              .init(color: .black, location: 0.16),
              .init(color: .black, location: 1),
            ]
            : [
              .init(color: .black, location: 0),
              .init(color: .black, location: 1),
            ],
          startPoint: .top,
          endPoint: .bottom
        )
      )
    }
  }
}

// MARK: - Diagnosis

/// Failure gets a sentence, not a stack trace: the first line says what happened,
/// the second what to do about it.
public struct DiagnosisBlock: View {
  var failure: HarnessFailure
  var copy: Copy
  var palette: Palette

  public init(failure: HarnessFailure, copy: Copy, palette: Palette) {
    self.failure = failure
    self.copy = copy
    self.palette = palette
  }

  public var body: some View {
    let text = copy.diagnosis(failure)
    VStack(alignment: .leading, spacing: 4) {
      Text(text.title)
        .font(Typography.heading)
        .foregroundStyle(palette.fail)
        .fixedSize(horizontal: false, vertical: true)
      Text(text.body)
        .font(Typography.body)
        .foregroundStyle(palette.inkSecondary)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
