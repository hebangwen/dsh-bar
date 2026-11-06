import AppKit
import DshBarKit
import SwiftUI

extension QuitBehavior: Identifiable {
  public var id: String { rawValue }
}

extension DshHomeMode: Identifiable {
  public var id: String { rawValue }
}

/// The four panes of the settings window. One tab strip, one pane at a time —
/// the same shape most Mac utilities use, because a column of eight unrelated
/// sections is a list to read rather than a window to use.
enum SettingsTab: String, Sendable, CaseIterable, Identifiable {
  case general
  case launch
  case workspace
  case environment
  case behavior

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .general: return "gearshape"
    case .launch: return "network"
    case .workspace: return "folder"
    case .environment: return "terminal"
    case .behavior: return "slider.horizontal.3"
    }
  }

  func title(_ copy: Copy) -> String {
    switch self {
    case .general: return copy.tabGeneral
    case .launch: return copy.tabLaunch
    case .workspace: return copy.tabWorkspace
    case .environment: return copy.tabEnvironment
    case .behavior: return copy.tabBehavior
    }
  }
}

/// Which launch-flag field owns the keyboard, so focus leaving the group is one
/// commit instead of five.
private enum LaunchField: Hashable {
  case host
  case publicURL
  case trustedHosts
  case tlsCert
  case tlsKey
}

/// The settings window: a tab strip on top, one pane below, labels right-aligned
/// against their controls.
///
/// Edits apply as they are made and go straight to `UserDefaults`, so there is no
/// Save button to forget. Text fields commit on Return or when focus leaves — a
/// half-typed path is not a path, and persisting one would make the panel explain a
/// failure the user did not ask for.
struct SettingsView: View {
  @ObservedObject var model: HarnessModel
  /// `ImageRenderer` does not lay out a `ScrollView`, so the offscreen snapshot asks
  /// for the same pane without one and at its full height.
  var scrolls: Bool = true

  @State private var tab: SettingsTab
  @State private var portText = ""
  @State private var portError = false
  @State private var profileText = ""
  @State private var workspaceText = ""
  @State private var dshHomeText = ""
  @State private var launchHostText = ""
  @State private var publicURLText = ""
  @State private var trustedHostsText = ""
  @State private var tlsCertText = ""
  @State private var tlsKeyText = ""
  @FocusState private var workspaceFocused: Bool
  @FocusState private var dshHomeFocused: Bool
  @FocusState private var launchFocus: LaunchField?

  @Environment(\.colorScheme) private var scheme

  init(model: HarnessModel, scrolls: Bool = true, tab: SettingsTab = .general) {
    _model = ObservedObject(wrappedValue: model)
    self.scrolls = scrolls
    _tab = State(initialValue: tab)
  }

  private var palette: Palette { Palette.forScheme(scheme) }
  private var copy: Copy { model.copy }
  private var labelFont: Font { .system(size: 12) }
  private var valueFont: Font { .system(size: 11.5, design: .monospaced) }

  /// Read from the bundle so bumping the version is one edit in Info.plist, not a
  /// second one hidden in a view.
  static var appVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
  }

  var body: some View {
    VStack(spacing: 0) {
      tabStrip
      Divider()
      Group {
        if scrolls {
          ScrollView { pane }
        } else {
          pane
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      footer
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
    .frame(
      width: SettingsMetrics.width,
      height: scrolls ? SettingsMetrics.height : SettingsMetrics.snapshotHeight,
      alignment: .topLeading
    )
    .onAppear {
      syncFields()
      model.refreshDocumentsAccess(probe: false)
      model.refreshLaunchAtLogin()
      if model.environmentReport == nil {
        model.rereadEnvironment()
      }
    }
    .onChange(of: model.preferences) { _, next in
      // The controller can change the port itself ("use a free port"), so the
      // fields follow the model rather than fighting it.
      if Int(portText.trimmingCharacters(in: .whitespaces)) != next.port {
        portText = next.isAutoPort ? "0" : String(next.port)
        portError = false
      }
      if profileText != next.profile {
        profileText = next.profile
      }
      if !workspaceFocused {
        let expected = next.workspacePath.map { LaunchTarget.shortPath($0) } ?? ""
        if workspaceText != expected { workspaceText = expected }
      }
      if !dshHomeFocused {
        let expected = next.dshHome.map { LaunchTarget.shortPath($0) } ?? ""
        if dshHomeText != expected { dshHomeText = expected }
      }
      mirrorLaunchFields(next)
    }
    .onChange(of: launchFocus) { _, focused in
      // Same rule as the path fields: a half-typed address is not an address, so
      // the value is committed when focus leaves the field, not per keystroke.
      if focused == nil { commitLaunchFields() }
    }
  }

  // MARK: - Tab strip

  /// Icon over word, one pane selected. The plate is a faint ink wash rather than an
  /// accent colour: the panel's whole vocabulary is monochrome, and the settings
  /// window is part of the same instrument.
  private var tabStrip: some View {
    HStack(spacing: 2) {
      Spacer(minLength: 0)
      ForEach(SettingsTab.allCases) { item in
        Button {
          tab = item
        } label: {
          VStack(spacing: 4) {
            Image(systemName: item.symbol)
              .font(.system(size: 17, weight: .regular))
            Text(item.title(copy))
              .font(.system(size: 10.5))
              .lineLimit(1)
          }
          .frame(width: 82, height: 52)
          .foregroundStyle(tab == item ? AnyShapeStyle(palette.ink) : AnyShapeStyle(palette.inkTertiary))
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(tab == item ? AnyShapeStyle(palette.ink.opacity(0.07)) : AnyShapeStyle(Color.clear))
          )
          .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title(copy))
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 6)
  }

  // MARK: - Panes

  @ViewBuilder
  private var pane: some View {
    switch tab {
    case .general: generalPane
    case .launch: launchPane
    case .workspace: workspacePane
    case .environment: environmentPane
    case .behavior: behaviorPane
    }
  }

  private var generalPane: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
      row(copy.binaryPath) {
        Text(model.detectedPath ?? copy.notDetected)
          .font(valueFont)
          .foregroundStyle(model.detectedPath == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(model.detectedPath ?? copy.chooseBinary)
        Spacer(minLength: 8)
        Button(copy.change) { chooseBinary() }
          .controlSize(.small)
        Button(copy.detectAgain) { model.refreshDetection() }
          .controlSize(.small)
      }
      if let detail = detectionDetail {
        note(detail)
      }

      row(copy.portField) {
        if isSnapshot {
          snapshotField(
            portText.isEmpty ? (model.preferences.isAutoPort ? "0" : String(model.preferences.port)) : portText,
            width: 78
          )
        } else {
          TextField("", text: $portText)
            .textFieldStyle(.roundedBorder)
            .font(valueFont)
            .frame(width: 78)
            .onChange(of: portText) { _, value in
              applyPort(value)
            }
        }
        if portError {
          Text(copy.portInvalid)
            .font(.system(size: 10.5))
            .foregroundStyle(palette.fail)
        } else if model.preferences.isAutoPort {
          Text(copy.portAuto)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 0)
      }

      row(copy.profileField) {
        if isSnapshot {
          snapshotField(profileText.isEmpty ? model.preferences.profile : profileText, width: 150)
        } else {
          TextField("", text: $profileText)
            .textFieldStyle(.roundedBorder)
            .font(valueFont)
            .frame(width: 150)
            .onChange(of: profileText) { _, value in
              model.update(profile: value)
            }
        }
        Spacer(minLength: 0)
      }

      row(copy.appearanceSection) {
        InkSegmented(
          selection: $model.appearance,
          options: AppearanceOverride.allCases,
          label: { $0.label(copy.language) }
        )
        Spacer(minLength: 0)
      }

      row(copy.launchAtLoginField) {
        if isSnapshot {
          snapshotToggle(on: model.launchAtLogin.isOn)
        } else {
          Toggle(
            "",
            isOn: Binding(
              get: { model.launchAtLogin.isOn },
              set: { model.setLaunchAtLogin($0) }
            )
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(!model.launchAtLogin.isOffered)
        }

        Text(copy.loginItemState(model.launchAtLogin))
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(loginItemStyle)

        Spacer(minLength: 8)
        if model.launchAtLogin == .requiresApproval {
          Button(copy.openLoginItems) { model.openLoginItemsSettings() }
            .controlSize(.small)
        }
      }
      if case let .unavailable(reason) = model.launchAtLogin {
        note(reason)
      }
    }
    .settingsPane(padding: SettingsMetrics.panePadding)
  }

  /// The fifth tab: the optional `dsh web` flags. Every field is blank by default,
  /// so an untouched install launches exactly the argv 0.5.0 launched.
  private var launchPane: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
      row(copy.hostField) {
        if isSnapshot {
          snapshotField(launchHostText.isEmpty ? copy.hostPlaceholder : launchHostText, width: 180)
        } else {
          TextField(copy.hostPlaceholder, text: $launchHostText)
            .textFieldStyle(.roundedBorder)
            .font(valueFont)
            .frame(width: 180)
            .focused($launchFocus, equals: .host)
            .onSubmit { commitLaunchFields() }
        }
        Spacer(minLength: 0)
      }
      note(
        launchProblem(.host).map(copy.launchFlagProblem) ?? copy.hostNote,
        tone: launchProblem(.host) == nil ? nil : palette.fail
      )

      row(copy.publicURLField) {
        if isSnapshot {
          snapshotField(publicURLText.isEmpty ? copy.publicURLPlaceholder : publicURLText, width: 240)
        } else {
          TextField(copy.publicURLPlaceholder, text: $publicURLText)
            .textFieldStyle(.roundedBorder)
            .font(valueFont)
            .frame(width: 240)
            .focused($launchFocus, equals: .publicURL)
            .onSubmit { commitLaunchFields() }
        }
        Spacer(minLength: 0)
      }
      note(
        launchProblem(.publicURL).map(copy.launchFlagProblem) ?? copy.publicURLNote,
        tone: launchProblem(.publicURL) == nil ? nil : palette.fail
      )

      row(copy.trustedHostsField) {
        if isSnapshot {
          snapshotField(trustedHostsText.isEmpty ? "—" : trustedHostsText, width: 240)
        } else {
          TextField("dsh.example.com, [::1]:8080", text: $trustedHostsText)
            .textFieldStyle(.roundedBorder)
            .font(valueFont)
            .frame(width: 240)
            .focused($launchFocus, equals: .trustedHosts)
            .onSubmit { commitLaunchFields() }
        }
        Spacer(minLength: 0)
      }
      note(
        launchProblem(.trustedHost).map(copy.launchFlagProblem) ?? copy.trustedHostsNote,
        tone: launchProblem(.trustedHost) == nil ? nil : palette.fail
      )

      row(copy.tlsCertField) {
        if isSnapshot {
          snapshotField(tlsCertText.isEmpty ? "—" : tlsCertText, width: 200)
        } else {
          TextField("", text: $tlsCertText)
            .textFieldStyle(.roundedBorder)
            .font(valueFont)
            .frame(width: 200)
            .focused($launchFocus, equals: .tlsCert)
            .onSubmit { commitLaunchFields() }
        }
        Button(copy.chooseLink) { chooseTLSFile(.tlsCert) }
          .controlSize(.small)
        Button(copy.clearField) {
          tlsCertText = ""
          commitLaunchFields()
        }
        .controlSize(.small)
        Spacer(minLength: 0)
      }

      row(copy.tlsKeyField) {
        if isSnapshot {
          snapshotField(tlsKeyText.isEmpty ? "—" : tlsKeyText, width: 200)
        } else {
          TextField("", text: $tlsKeyText)
            .textFieldStyle(.roundedBorder)
            .font(valueFont)
            .frame(width: 200)
            .focused($launchFocus, equals: .tlsKey)
            .onSubmit { commitLaunchFields() }
        }
        Button(copy.chooseLink) { chooseTLSFile(.tlsKey) }
          .controlSize(.small)
        Button(copy.clearField) {
          tlsKeyText = ""
          commitLaunchFields()
        }
        .controlSize(.small)
        Spacer(minLength: 0)
      }
      let tlsProblem = launchProblem(.tlsCert) ?? launchProblem(.tlsKey)
      note(
        tlsProblem.map(copy.launchFlagProblem) ?? copy.tlsNote,
        tone: tlsProblem == nil ? nil : palette.fail
      )

      row(copy.patchField) {
        VStack(alignment: .leading, spacing: 5) {
          if model.preferences.patchPaths.isEmpty {
            Text(copy.noPatches)
              .font(.system(size: 10.5))
              .foregroundStyle(.tertiary)
          } else {
            ForEach(model.preferences.patchPaths, id: \.self) { path in
              HStack(spacing: 8) {
                Text(LaunchTarget.shortPath(path))
                  .font(valueFont)
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .help(path)
                if !isSnapshot {
                  Button(copy.removePatch) { model.removePatch(path) }
                    .controlSize(.small)
                }
              }
            }
          }
          if !isSnapshot {
            Button(copy.addPatch) { choosePatches() }
              .controlSize(.small)
          }
        }
        Spacer(minLength: 0)
      }
      if let problem = launchProblem(.patch) {
        note(copy.launchFlagProblem(problem), tone: palette.fail)
      }
    }
    .settingsPane(padding: SettingsMetrics.panePadding)
  }

  private var workspacePane: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
      row(copy.workspaceField) {
        if isSnapshot {
          snapshotField(
            workspaceText.isEmpty ? copy.workspacePlaceholder : workspaceText,
            width: 250
          )
        } else {
          TextField(copy.workspacePlaceholder, text: $workspaceText)
            .textFieldStyle(.roundedBorder)
            .font(valueFont)
            .focused($workspaceFocused)
            .onSubmit { applyWorkspace() }
            .onChange(of: workspaceFocused) { _, focused in
              if !focused { applyWorkspace() }
            }
        }
        Button(copy.chooseLink) { chooseWorkspace() }
          .controlSize(.small)
        Button(copy.useDefault) {
          // Clearing the text as well: while the field still has focus the
          // preferences-change mirror is suppressed, and a later blur would write
          // the old text straight back.
          workspaceText = ""
          model.update(workspacePath: nil)
        }
        .controlSize(.small)
      }
      if let problem = model.launchTarget.workspaceProblem {
        note(problemText(problem), tone: palette.fail)
      } else {
        note(copy.workspaceNote)
      }

      row(copy.dshHomeField) {
        InkSegmented(
          selection: Binding(
            get: { model.preferences.dshHomeMode },
            set: { mode in
            if mode == .followShell { dshHomeText = "" }
            model.update(dshHomeMode: mode)
          }
          ),
          options: DshHomeMode.allCases,
          label: { $0 == .followShell ? copy.followShell : copy.overrideShell }
        )
        if model.preferences.dshHomeMode == .override {
          if isSnapshot {
            snapshotField(dshHomeText.isEmpty ? BarPreferences.defaultDshHome : dshHomeText, width: 180)
          } else {
            TextField(BarPreferences.defaultDshHome, text: $dshHomeText)
              .textFieldStyle(.roundedBorder)
              .font(valueFont)
              .focused($dshHomeFocused)
              .onSubmit { applyDshHome() }
              .onChange(of: dshHomeFocused) { _, focused in
                if !focused { applyDshHome() }
              }
          }
        }
        Spacer(minLength: 0)
      }
      note(
        model.launchTarget.dshHomeProblem.map(problemText) ?? copy.dshHomeNote,
        tone: model.launchTarget.dshHomeProblem == nil ? nil : palette.fail
      )

      Divider().padding(.vertical, 2)

      row(copy.documentsFolder) {
        Text(model.documentsFolder.displayPath)
          .font(valueFont)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(model.documentsFolder.folder.path)
        Text(copy.folderState(model.documentsFolder))
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(folderStateStyle)
          .fixedSize()
        Spacer(minLength: 8)
      }
      note(folderNote)

      HStack(spacing: 8) {
        Spacer().frame(width: SettingsMetrics.labelWidth + 14)
        Button(copy.recheck) { model.refreshDocumentsAccess() }
          .controlSize(.small)
        Button(copy.authorize) { model.grantDocumentsFolder() }
          .controlSize(.small)
        Button(copy.openSystemSettings) { model.openPrivacySettings() }
          .controlSize(.small)
        Spacer(minLength: 0)
      }
    }
    .settingsPane(padding: SettingsMetrics.panePadding)
  }

  private var environmentPane: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
      if let report = model.environmentReport {
        row(copy.environmentSourceField) {
          Text(copy.environmentSource(report.source))
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        row(copy.environmentPathField) {
          Text(report.pathHead.isEmpty ? "—" : report.pathHead)
            .font(valueFont)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(report.pathHead)
          Spacer(minLength: 0)
        }
        row(copy.environmentNodeField) {
          Text(nodeText(report))
            .font(valueFont)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(report.nodePath ?? copy.environmentNodeMissing)
          Spacer(minLength: 0)
        }
        row(copy.environmentTimingField) {
          Text(copy.environmentTiming(report))
            .font(valueFont)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        if report.failureNote != nil {
          note(environmentNote(report), tone: palette.warn)
        }
      } else {
        row(copy.environmentSourceField) {
          Text(copy.reading)
            .font(valueFont)
            .foregroundStyle(.tertiary)
          Spacer(minLength: 0)
        }
      }

      HStack(spacing: 8) {
        Spacer().frame(width: SettingsMetrics.labelWidth + 14)
        Button(copy.reread) { model.rereadEnvironment() }
          .controlSize(.small)
        Spacer(minLength: 0)
      }
    }
    .settingsPane(padding: SettingsMetrics.panePadding)
  }

  private var behaviorPane: some View {
    VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) {
      row(copy.quitField) {
        InkSegmented(
          selection: Binding(
            get: { model.preferences.quitBehavior },
            set: { model.update(quitBehavior: $0) }
          ),
          options: QuitBehavior.allCases,
          label: { QuitBehavior.label($0, language: copy.language) }
        )
        Spacer(minLength: 0)
      }
      note(copy.quitNote)

      row(copy.sleepField) {
        InkSegmented(
          selection: Binding(
            get: { model.preferences.sleepPolicy },
            set: { model.update(sleepPolicy: $0) }
          ),
          options: SleepPolicy.allCases,
          label: { SleepPolicy.label($0, language: copy.language) }
        )
        Text(copy.sleepState(model.sleepStatus))
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(sleepStateStyle)
          .fixedSize()
        Spacer(minLength: 0)
      }
      note(sleepNote, tone: sleepNoteTone)

      row(copy.shortcutField) {
        InkSegmented(
          selection: Binding(
            get: { model.preferences.hotKey },
            set: { model.update(hotKey: $0) }
          ),
          options: HotKeyChoice.allCases,
          label: { $0.label(language: copy.language) }
        )
        Spacer(minLength: 0)
      }
      if model.hotKeyStatus == .taken {
        note(copy.shortcutTaken, tone: palette.fail)
      } else {
        note(copy.shortcutNote)
      }
    }
    .settingsPane(padding: SettingsMetrics.panePadding)
  }

  // MARK: - Rows

  /// Label right-aligned against a fixed column, controls after it. The reference for
  /// this shape is every System Settings pane on macOS: the eye follows one vertical
  /// line instead of reading a list.
  private func row<Content: View>(
    _ label: String,
    @ViewBuilder _ content: () -> Content
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      Text(label)
        .font(labelFont)
        .foregroundStyle(.secondary)
        .frame(width: SettingsMetrics.labelWidth, alignment: .trailing)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
      content()
    }
  }

  /// `ImageRenderer` cannot draw AppKit-backed controls (`TextField`, `.switch`), so
  /// an offscreen sheet that kept them would be a wall of yellow "no entry" boxes.
  /// The snapshot path draws quiet read-only stand-ins with the same geometry, and
  /// what the reader sees is the value a real field would be showing.
  private var isSnapshot: Bool { !scrolls }

  private func snapshotField(_ text: String, width: CGFloat) -> some View {
    Text(text)
      .font(valueFont)
      .foregroundStyle(.primary)
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(.horizontal, 6)
      .frame(width: width, height: 20, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.primary.opacity(0.04))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(palette.rule, lineWidth: 1)
      )
  }

  private func snapshotToggle(on: Bool) -> some View {
    HStack(spacing: 0) {
      if on { Spacer(minLength: 0) }
      Circle()
        .fill(Color(nsColor: .windowBackgroundColor))
        .frame(width: 12, height: 12)
        .padding(2)
      if !on { Spacer(minLength: 0) }
    }
    .frame(width: 30, height: 16)
    .background(Capsule().fill(on ? AnyShapeStyle(palette.ink) : AnyShapeStyle(palette.rule)))
  }

  /// The one-line explanation under a row, aligned with the controls.
  private func note(_ text: String, tone: Color? = nil) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Spacer().frame(width: SettingsMetrics.labelWidth + 14)
      Text(text)
        .font(.system(size: 10.5))
        .foregroundStyle(tone.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tertiary))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private var loginItemStyle: AnyShapeStyle {
    switch model.launchAtLogin {
    case .enabled: return AnyShapeStyle(.secondary)
    case .requiresApproval: return AnyShapeStyle(palette.warn)
    case .notRegistered, .unavailable: return AnyShapeStyle(.tertiary)
    }
  }

  /// The row's chip is the guard's own status: a preference that says "on" while
  /// caffeinate is missing must not read as green.
  private var sleepStateStyle: AnyShapeStyle {
    switch model.sleepStatus {
    case .asserting: return AnyShapeStyle(.secondary)
    case .idle: return AnyShapeStyle(.tertiary)
    case .unavailable: return AnyShapeStyle(palette.fail)
    case .failed: return AnyShapeStyle(palette.warn)
    }
  }

  private var sleepNote: String {
    switch model.sleepStatus {
    case .unavailable, .failed:
      return copy.sleepState(model.sleepStatus)
    case .idle, .asserting:
      return copy.sleepNote
    }
  }

  private var sleepNoteTone: Color? {
    switch model.sleepStatus {
    case .unavailable: return palette.fail
    case .failed: return palette.warn
    case .idle, .asserting: return nil
    }
  }

  private var folderStateStyle: AnyShapeStyle {
    switch model.documentsFolder.state {
    case .granted: return AnyShapeStyle(.secondary)
    case .denied: return AnyShapeStyle(palette.fail)
    case .notRequested: return AnyShapeStyle(palette.warn)
    case .missing: return AnyShapeStyle(palette.fail)
    }
  }

  private var folderNote: String {
    if let error = model.folderError {
      return error
    }
    return model.documentsFolder.state == .denied ? copy.folderDeniedNote : copy.folderNote
  }

  private func problemText(_ problem: LaunchPathProblem) -> String {
    switch problem {
    case .relative:
      return copy.relativePathRejected
    case .notDirectory(let path):
      return copy.notAFolder(path)
    case .missing(let path):
      return copy.noSuchFolder(path)
    }
  }

  private func nodeText(_ report: EnvironmentReport) -> String {
    guard let path = report.nodePath else { return copy.environmentNodeMissing }
    guard let version = report.nodeVersion else { return LaunchTarget.shortPath(path) }
    return "\(version) · \(LaunchTarget.shortPath(path))"
  }

  private func environmentNote(_ report: EnvironmentReport) -> String {
    switch report.source {
    case .process: return copy.environmentFallbackNote
    case .loginShell: return copy.environmentLoginShellNote
    case .interactiveShell: return copy.environmentNodeMissing
    }
  }

  // MARK: - Launch flags

  private func launchProblem(_ field: WebLaunchFlags.Field) -> WebLaunchFlags.Problem? {
    model.launchFlagProblems.first { $0.field == field }
  }

  /// The model is the source of truth; the fields only mirror it. A field that
  /// currently has focus is left alone, because writing the stored value back into
  /// a half-typed field is how a text field starts fighting the user.
  private func mirrorLaunchFields(_ preferences: BarPreferences) {
    if launchFocus != .host {
      let expected = preferences.launchHost ?? ""
      if launchHostText != expected { launchHostText = expected }
    }
    if launchFocus != .publicURL {
      let expected = preferences.publicURL ?? ""
      if publicURLText != expected { publicURLText = expected }
    }
    if launchFocus != .trustedHosts {
      let expected = preferences.trustedHostsText
      if trustedHostsText != expected { trustedHostsText = expected }
    }
    if launchFocus != .tlsCert {
      let expected = preferences.tlsCertPath ?? ""
      if tlsCertText != expected { tlsCertText = expected }
    }
    if launchFocus != .tlsKey {
      let expected = preferences.tlsKeyPath ?? ""
      if tlsKeyText != expected { tlsKeyText = expected }
    }
  }

  private func commitLaunchFields() {
    var next = model.preferences
    next.launchHost = BarPreferences.normalizeHost(launchHostText)
    next.publicURL = BarPreferences.normalizeURL(publicURLText)
    next.trustedHosts = BarPreferences.normalizeTrustedHosts([trustedHostsText])
    next.tlsCertPath = BarPreferences.normalizeFilePath(tlsCertText)
    next.tlsKeyPath = BarPreferences.normalizeFilePath(tlsKeyText)
    model.applyLaunchFlags(next.launchFlags)
  }

  private func chooseTLSFile(_ field: WebLaunchFlags.Field) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = field == .tlsKey ? copy.tlsKeyField : copy.tlsCertField
    panel.prompt = copy.chooseLink
    guard panel.runModal() == .OK, let url = panel.url else { return }
    if field == .tlsKey {
      tlsKeyText = url.path
    } else {
      tlsCertText = url.path
    }
    commitLaunchFields()
  }

  private func choosePatches() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.message = copy.patchField
    panel.prompt = copy.addPatch
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      model.addPatch(url.path)
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 8) {
      if model.demoMode {
        Text(copy.demoMode)
          .font(.system(size: 10.5))
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      Text("dsh bar \(Self.appVersion)")
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
  }

  private var detectionDetail: String? {
    guard model.detectedPath != nil else {
      return copy.detectionMissing
    }
    var parts: [String] = []
    if let source = model.detectedSource {
      parts.append(copy.binarySource(source))
    }
    parts.append(copy.versionLabel(model.dshVersion))
    return parts.joined(separator: " · ")
  }

  // MARK: - Actions

  private func applyPort(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard let port = Int(trimmed), (0...65535).contains(port) else {
      portError = true
      return
    }
    portError = false
    model.update(port: port)
  }

  private func applyWorkspace() {
    let trimmed = workspaceText.trimmingCharacters(in: .whitespaces)
    let normalized = BarPreferences.normalizeWorkspacePath(trimmed)
    model.update(workspacePath: normalized)
    workspaceText = normalized.map { LaunchTarget.shortPath($0) } ?? ""
  }

  private func applyDshHome() {
    let trimmed = dshHomeText.trimmingCharacters(in: .whitespaces)
    let normalized = BarPreferences.normalizeDshHome(trimmed)
    model.update(dshHome: normalized)
    dshHomeText = normalized.map { LaunchTarget.shortPath($0) } ?? ""
  }

  private func chooseWorkspace() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.message = copy.workspaceChooseMessage
    panel.prompt = copy.change
    if panel.runModal() == .OK, let url = panel.url {
      model.update(workspacePath: url.path)
      workspaceText = LaunchTarget.shortPath(url.path)
    }
  }

  private func syncFields() {
    portText = model.preferences.isAutoPort ? "0" : String(model.preferences.port)
    profileText = model.preferences.profile
    portError = false
    workspaceText = model.preferences.workspacePath.map { LaunchTarget.shortPath($0) } ?? ""
    dshHomeText = model.preferences.dshHome.map { LaunchTarget.shortPath($0) } ?? ""
    mirrorLaunchFields(model.preferences)
  }

  private func chooseBinary() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.message = copy.chooseBinary
    panel.prompt = copy.change
    if panel.runModal() == .OK, let url = panel.url {
      model.chooseBinary(url.path)
    }
  }
}

/// The settings window is a fixed-size window, so its geometry lives in one place:
/// the view, the window, and the offscreen snapshot renderer all read it.
enum SettingsMetrics {
  static let width: CGFloat = 560
  /// The scrolling window.
  static let height: CGFloat = 470
  /// The offscreen snapshot: no scroll view, so the tallest pane has to fit. Same as
  /// the window, otherwise the sheet is shorter than what people actually see.
  static let snapshotHeight: CGFloat = 470
  /// The label column every row right-aligns against.
  static let labelWidth: CGFloat = 118
  static let rowGap: CGFloat = 16
  static let panePadding: CGFloat = 24
}

private extension View {
  func settingsPane(padding: CGFloat) -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, padding)
      .padding(.top, 20)
      .padding(.bottom, 24)
  }
}

/// A monochrome stand-in for the system segmented control, so settings share the
/// panel's vocabulary instead of introducing the only accent colour in the app.
struct InkSegmented<Option: Identifiable & Hashable>: View {
  @Binding var selection: Option
  var options: [Option]
  var label: (Option) -> String

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options) { option in
        Button {
          selection = option
        } label: {
          Text(label(option))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(
              selection == option
                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                : AnyShapeStyle(HierarchicalShapeStyle.secondary)
            )
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selection == option ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.primary.opacity(0.07))
    )
  }
}
