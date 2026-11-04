import SwiftUI

public enum PanelAction: Sendable, Equatable {
  case primary
  case secondary
  case restart
  case copyLink
  case takeOver
  case openLog
  case settings
  case quit
  case chooseBinary
}

/// The whole appearance in one value-driven view.
///
/// It takes a `HarnessSnapshot` and a closure: no process, no timers, no
/// `Date.now`. That is what makes the same code serve the app, the snapshot
/// tool, and the prototype you can click through.
public struct PanelView: View {
  public var snapshot: HarnessSnapshot
  public var copy: Copy
  public var palette: Palette
  public var actions: (PanelAction) -> Void

  public init(
    snapshot: HarnessSnapshot,
    copy: Copy,
    palette: Palette,
    actions: @escaping (PanelAction) -> Void = { _ in }
  ) {
    self.snapshot = snapshot
    self.copy = copy
    self.palette = palette
    self.actions = actions
  }

  public var body: some View {
    VStack(spacing: 0) {
      masthead
      hero
      readoutBand
      if snapshot.phase == .failed, let failure = snapshot.failure {
        DiagnosisBlock(failure: failure, copy: copy, palette: palette)
          .padding(.horizontal, Metrics.pad)
          .padding(.top, Metrics.actionTop)
      }
      if snapshot.phase == .unavailable {
        unavailableNote
      }
      actionsSection
        .padding(.top, Metrics.actionTop)
      detailSection
      footer
    }
    .frame(width: Metrics.panelWidth)
    .background(palette.plate)
    .clipShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
        .strokeBorder(palette.rule.opacity(0.55), lineWidth: 0.5)
    )
  }

  // MARK: Masthead

  private var masthead: some View {
    HStack(spacing: 8) {
      BrandMark(palette: palette)
      Text(copy.wordmark)
        .font(Typography.wordmark)
        .tracking(1.0)
        .foregroundStyle(palette.ink)
      Spacer(minLength: 8)
      Button {
        actions(.settings)
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 12, weight: .regular))
          .foregroundStyle(palette.inkTertiary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(copy.settings)
    }
    .padding(.horizontal, Metrics.pad)
    .padding(.top, Metrics.mastheadTop)
  }

  // MARK: Hero

  private var hero: some View {
    HStack(spacing: 6) {
      RingLamp(phase: snapshot.phase, owner: snapshot.owner, palette: palette)
      Text(copy.stateWord(snapshot.phase))
        .font(Typography.hero(copy.language))
        .tracking(Typography.heroTracking(copy.language))
        .foregroundStyle(palette.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Metrics.pad)
    .padding(.top, Metrics.heroTop)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(copy.stateWord(snapshot.phase))
  }

  // MARK: Readout band

  /// The one recessed surface on the panel: a display window showing what the
  /// server is, not what it could be. Full-bleed so it reads as part of the
  /// device rather than as a card.
  private var readoutBand: some View {
    VStack(spacing: 0) {
      Rectangle().fill(palette.rule).frame(height: 1)
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(snapshot.address)
          .font(Typography.readout)
          .tracking(0.2)
          .foregroundStyle(palette.ink.opacity(snapshot.phase == .stopped ? 0.4 : 0.66))
          .lineLimit(1)
        Spacer(minLength: 8)
        if let side = copy.readoutSide(snapshot) {
          Text(side)
            .font(Typography.meta)
            .foregroundStyle(palette.inkTertiary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, Metrics.pad)
      .padding(.vertical, Metrics.bandPadVertical)
      .frame(maxWidth: .infinity)
      .background(palette.well)
      Rectangle().fill(palette.rule.opacity(0.55)).frame(height: 1)
    }
    .padding(.top, Metrics.bandTop)
  }

  // MARK: Actions

  private var primaryIsEnabled: Bool {
    switch snapshot.phase {
    case .starting, .stopping: return false
    default: return !snapshot.busy
    }
  }

  @ViewBuilder
  private var actionsSection: some View {
    Group {
      switch snapshot.phase {
      case .listening:
        HStack(spacing: Metrics.actionGap) {
          Button { actions(.primary) } label: {
            Text(copy.primaryLabel(snapshot))
          }
          .buttonStyle(PrimaryActionStyle(palette: palette, isEnabled: snapshot.hasLaunchURL || snapshot.owner == .external))
          .disabled(!snapshot.hasLaunchURL && snapshot.owner == .dshBar)

          if snapshot.owner == .external {
            // Stop lives in the tertiary row; the primary secondary action is the
            // one that gives the app control, and it says so before it acts.
            Button { actions(.takeOver) } label: {
              Text(copy.takeOverLabel)
            }
            .buttonStyle(OutlineActionStyle(palette: palette))
            .frame(width: 110)
          } else {
            Button { actions(.secondary) } label: {
              Text(copy.secondaryLabel(snapshot) ?? "")
            }
            .buttonStyle(OutlineActionStyle(palette: palette))
            .frame(width: 84)
          }
        }
        .padding(.bottom, 5)
        tertiaryRow

      case .starting:
        // The only useful thing while starting is to cancel, so it *is* the action.
        Button { actions(.secondary) } label: {
          Text(copy.cancel)
        }
        .buttonStyle(OutlineActionStyle(palette: palette))

      case .stopping:
        EmptyView()

      case .failed:
        if let secondary = copy.secondaryLabel(snapshot), snapshot.failure?.port != nil {
          HStack(spacing: Metrics.actionGap) {
            Button { actions(.primary) } label: {
              Text(copy.primaryLabel(snapshot))
            }
            .buttonStyle(PrimaryActionStyle(palette: palette, isEnabled: primaryIsEnabled))

            Button { actions(.secondary) } label: {
              Text(secondary)
            }
            .buttonStyle(OutlineActionStyle(palette: palette))
            .frame(width: 132)
          }
        } else {
          Button { actions(.primary) } label: {
            Text(copy.primaryLabel(snapshot))
          }
          .buttonStyle(PrimaryActionStyle(palette: palette, isEnabled: primaryIsEnabled))
        }

      case .unavailable, .stopped:
        Button { actions(.primary) } label: {
          Text(copy.primaryLabel(snapshot))
        }
        .buttonStyle(PrimaryActionStyle(palette: palette, isEnabled: primaryIsEnabled))
      }
    }
    .padding(.horizontal, Metrics.pad)
  }

  private var tertiaryRow: some View {
    HStack(spacing: 16) {
      if snapshot.owner == .external {
        Button { actions(.secondary) } label: {
          Text(copy.secondaryLabel(snapshot) ?? copy.takeOver)
        }
        .buttonStyle(TextActionStyle(palette: palette))
      } else {
        Button { actions(.restart) } label: { Text(copy.restart) }
          .buttonStyle(TextActionStyle(palette: palette))
        Button { actions(.copyLink) } label: { Text(copy.copyLink) }
          .buttonStyle(TextActionStyle(palette: palette))
          .disabled(!snapshot.hasLaunchURL)
          .opacity(snapshot.hasLaunchURL ? 1 : 0.4)
      }
      Spacer(minLength: 0)
    }
  }

  // MARK: Detail

  @ViewBuilder
  private var detailSection: some View {
    switch snapshot.phase {
    case .listening:
      if snapshot.owner == .external {
        externalNote
      } else if !snapshot.log.isEmpty {
        LogTail(lines: snapshot.log, copy: copy, palette: palette, onOpenLog: { actions(.openLog) })
          .padding(.horizontal, Metrics.pad)
          .padding(.top, Metrics.detailTop)
      }
    case .failed:
      LogTail(lines: snapshot.log, copy: copy, palette: palette, maxLines: 3, onOpenLog: { actions(.openLog) })
        .padding(.horizontal, Metrics.pad)
        .padding(.top, Metrics.detailTop + 4)
    case .stopped, .starting, .stopping, .unavailable:
      EmptyView()
    }
  }

  private var externalNote: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(copy.externalNote)
        .font(Typography.body)
        .foregroundStyle(palette.inkSecondary)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
      Text(copy.takeOverNote)
        .font(Typography.body)
        .foregroundStyle(palette.warn)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Metrics.pad)
    .padding(.top, Metrics.detailTop)
  }

  private var unavailableNote: some View {
    Text(copy.unavailableBody)
      .font(Typography.body)
      .foregroundStyle(palette.inkSecondary)
      .lineSpacing(3)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Metrics.pad)
      .padding(.top, Metrics.actionTop)
  }

  // MARK: Footer

  private var footer: some View {
    VStack(spacing: 0) {
      EngravedRule(palette: palette)
        .padding(.top, 10)
      HStack(spacing: 14) {
        Button { actions(.settings) } label: {
          Text(copy.portLabel(snapshot.port))
            .font(Typography.meta)
            .foregroundStyle(palette.inkTertiary)
        }
        .buttonStyle(.plain)

        Button { actions(.settings) } label: {
          Text(copy.profileLabel(snapshot.profile))
            .font(Typography.meta)
            .foregroundStyle(palette.inkTertiary)
        }
        .buttonStyle(.plain)

        Spacer(minLength: 8)

        Button { actions(.quit) } label: {
          Text(copy.quit)
            .font(Typography.meta)
            .foregroundStyle(palette.inkTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copy.quit)
      }
      .padding(.horizontal, Metrics.pad)
      .frame(height: Metrics.footerHeight)
      .padding(.bottom, Metrics.footerBottomPad)
    }
  }
}
