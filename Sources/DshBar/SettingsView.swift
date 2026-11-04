import AppKit
import DshBarKit
import SwiftUI

/// The settings surface: the three values process control actually needs, plus
/// the appearance switch from the first pass.
///
/// Edits apply immediately and are written to `UserDefaults`, so there is no Save
/// button to forget. Validation is inline: an unusable port is reported next to
/// the field and simply is not applied.
struct SettingsView: View {
  @ObservedObject var model: HarnessModel

  @State private var portText = ""
  @State private var portError = false
  @State private var profileText = ""

  private var copy: Copy { model.copy }
  private var labelFont: Font { .system(size: 12) }

  /// Read from the bundle so bumping the version is one edit in Info.plist, not a
  /// second one hidden in a view.
  static var appVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionTitle(copy.processSection)

      binaryRow
      if let detail = detectionDetail {
        Text(detail)
          .font(.system(size: 10.5))
          .foregroundStyle(.tertiary)
          .padding(.leading, 104)
          .padding(.top, 4)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider().padding(.vertical, 14)

      HStack(spacing: 12) {
        Text(copy.portField)
          .font(labelFont)
          .foregroundStyle(.secondary)
          .frame(width: 92, alignment: .leading)
        TextField("", text: $portText)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 11.5, design: .monospaced))
          .frame(width: 78)
          .onChange(of: portText) { _, value in
            applyPort(value)
          }
        if portError {
          Text(copy.portInvalid)
            .font(.system(size: 10.5))
            .foregroundStyle(Color.red)
        } else if model.preferences.isAutoPort {
          Text(copy.portAuto)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 12) {
        Text(copy.profileField)
          .font(labelFont)
          .foregroundStyle(.secondary)
          .frame(width: 92, alignment: .leading)
        TextField("", text: $profileText)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 11.5, design: .monospaced))
          .frame(width: 140)
          .onChange(of: profileText) { _, value in
            model.update(profile: value)
          }
        Spacer(minLength: 0)
      }
      .padding(.top, 10)

      Divider().padding(.vertical, 14)

      sectionTitle(copy.appearanceSection)

      HStack(spacing: 12) {
        Spacer(minLength: 0)
        InkSegmented(
          selection: $model.appearance,
          options: AppearanceOverride.allCases,
          label: { $0.label(copy.language) }
        )
      }

      Spacer(minLength: 12)

      footer
    }
    .padding(20)
    .frame(width: 460, height: 312, alignment: .topLeading)
    .onAppear(perform: syncFields)
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
    }
  }

  // MARK: - Rows

  private var binaryRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(copy.binaryPath)
        .font(labelFont)
        .foregroundStyle(.secondary)
        .frame(width: 92, alignment: .leading)

      Text(model.detectedPath ?? copy.notDetected)
        .font(.system(size: 11.5, design: .monospaced))
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
  }

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

  private func sectionTitle(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(.secondary)
      .padding(.bottom, 10)
  }

  private var detectionDetail: String? {
    guard model.detectedPath != nil else {
      return copy.language == .zhHans
        ? "在登录 shell 的 PATH、nvm、Homebrew 里都没找到。"
        : "Not on the login shell PATH, in nvm, or in Homebrew."
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

  private func syncFields() {
    portText = model.preferences.isAutoPort ? "0" : String(model.preferences.port)
    profileText = model.preferences.profile
    portError = false
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
