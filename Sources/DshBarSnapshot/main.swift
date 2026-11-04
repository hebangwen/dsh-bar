import AppKit
import SwiftUI
import DshBarKit

/// Renders the panel offscreen, so the appearance can be reviewed as images
/// without screen-recording permission and without opening the app.
///
///   swift run dshbar-snap [output-directory]
///
/// Writes one transparent PNG per scene, plus a labelled contact sheet per
/// language for quick review.

@main
struct SnapshotMain {
  @MainActor
  static func main() {
    let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/design"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    for language in UILanguage.allCases {
      let copy = Copy(language: language)
      var light: [(DemoScene, NSImage)] = []
      var dark: [(DemoScene, NSImage)] = []

      for scene in DemoScene.allCases {
        for scheme in [ColorScheme.light, .dark] {
          let palette = Palette.forScheme(scheme)
          let snapshot = Fixtures.snapshot(for: scene, copy: copy)
          let view = PanelView(snapshot: snapshot, copy: copy, palette: palette)
            .environment(\.colorScheme, scheme)
          guard let image = renderPanel(view) else {
            print("render failed: \(scene.title) \(scheme) \(language.rawValue)")
            continue
          }
          let name = "panel-\(scene.title)-\(scheme == .dark ? "dark" : "light")-\(language.rawValue).png"
          write(image, to: "\(outDir)/\(name)")
          if scheme == .dark { dark.append((scene, image)) } else { light.append((scene, image)) }
        }
      }

      if let sheet = contactSheet(light: light, dark: dark, language: language) {
        write(sheet, to: "\(outDir)/sheet-\(language.rawValue).png")
      }
      print("wrote \(outDir) [\(language.rawValue)]")
    }

    writeIconSheet(to: "\(outDir)/sheet-menu-bar-icons.png")
    print("wrote \(outDir) [menu bar icons]")

    writeMotionSheet(to: "\(outDir)/sheet-menu-bar-motion.png")
    print("wrote \(outDir) [menu bar motion]")
  }

  // MARK: - Motion filmstrip

  /// A still sheet cannot show motion, so the rotation and the arrival pulse are
  /// documented as sampled frames.
  @MainActor
  static func writeMotionSheet(to path: String) {
    let starting = StatusIcon.frames(for: .starting, owner: .dshBar) ?? []
    let stopping = StatusIcon.frames(for: .stopping, owner: .dshBar) ?? []
    let pulse = StatusIcon.arrivalPulse(for: .dshBar)
    let rows: [(String, [NSImage])] = [
      ("starting · clockwise · 1s per turn", starting),
      ("stopping · counter-clockwise · 1s per turn", stopping),
      ("listening · one pulse · 0.4s", pulse),
    ]

    let columns = 8
    let cell: CGFloat = 52
    let rowHeight: CGFloat = 74
    let width = cell * CGFloat(columns) + 40
    let height = rowHeight * CGFloat(rows.count) + 24

    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * 2),
        pixelsHigh: Int(height * 2),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return }
    bitmap.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    for (row, entry) in rows.enumerated() {
      let top = height - 12 - CGFloat(row) * rowHeight
      let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1),
      ]
      NSAttributedString(string: entry.0, attributes: labelAttributes)
        .draw(at: NSPoint(x: 16, y: top - 12))

      let frames = entry.1
      let step = max(1, frames.count / columns)
      let sampled = stride(from: 0, to: frames.count, by: step).prefix(columns)
      for (index, frameIndex) in sampled.enumerated() {
        let x = 20 + CGFloat(index) * cell
        let tinted = tinted(frames[frameIndex], color: .white)
        tinted.draw(in: NSRect(x: x, y: top - 58, width: 36, height: 36))
      }
    }

    NSGraphicsContext.restoreGraphicsState()

    guard
      let tiff = bitmap.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]),
      let image = NSImage(data: png)
    else { return }
    write(image, to: path)
  }

  // MARK: - Menu bar icons

  /// The status item is a template image: shape carries the state, the menu bar
  /// supplies the colour. This sheet shows both bar tones at 4x.
  @MainActor
  static func writeIconSheet(to path: String) {
    struct Sample {
      let title: String
      let phase: HarnessPhase
      let owner: ServerOwner
    }
    let samples: [Sample] = [
      Sample(title: "unavailable", phase: .unavailable, owner: .dshBar),
      Sample(title: "stopped", phase: .stopped, owner: .dshBar),
      Sample(title: "starting (cw)", phase: .starting, owner: .dshBar),
      Sample(title: "listening", phase: .listening, owner: .dshBar),
      Sample(title: "external", phase: .listening, owner: .external),
      Sample(title: "stopping (ccw)", phase: .stopping, owner: .dshBar),
      Sample(title: "failed", phase: .failed, owner: .dshBar),
    ]

    let scale: CGFloat = 4
    let cell: CGFloat = 18 * scale + 44
    let width = cell * CGFloat(samples.count) + 32
    let rowHeight: CGFloat = 18 * scale + 54
    let height = rowHeight * 2 + 40

    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * 2),
        pixelsHigh: Int(height * 2),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return }
    bitmap.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let bars: [(NSColor, NSColor, String)] = [
      (NSColor(calibratedWhite: 0.93, alpha: 1), NSColor.black, "light menu bar"),
      (NSColor(calibratedWhite: 0.16, alpha: 1), NSColor.white, "dark menu bar"),
    ]

    for (row, bar) in bars.enumerated() {
      let barY = height - CGFloat(row + 1) * rowHeight - 40
      bar.0.setFill()
      NSRect(x: 0, y: barY, width: width, height: rowHeight).fill()

      for (index, sample) in samples.enumerated() {
        let icon = StatusIcon.image(for: sample.phase, owner: sample.owner)
        let tinted = tinted(icon, color: bar.1)
        let x = 16 + CGFloat(index) * cell
        tinted.draw(in: NSRect(x: x, y: barY + 30, width: 18 * scale, height: 18 * scale))

        let attributes: [NSAttributedString.Key: Any] = [
          .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
          .foregroundColor: row == 0 ? NSColor(calibratedWhite: 0.35, alpha: 1) : NSColor(calibratedWhite: 0.8, alpha: 1),
        ]
        NSAttributedString(string: sample.title, attributes: attributes)
          .draw(at: NSPoint(x: x, y: barY + 12))
      }

      let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
        .foregroundColor: row == 0 ? NSColor(calibratedWhite: 0.4, alpha: 1) : NSColor(calibratedWhite: 0.75, alpha: 1),
      ]
      NSAttributedString(string: bar.2, attributes: labelAttributes)
        .draw(at: NSPoint(x: 16, y: barY + rowHeight - 20))
    }

    NSGraphicsContext.restoreGraphicsState()

    guard
      let tiff = bitmap.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]),
      let image = NSImage(data: png)
    else { return }
    write(image, to: path)
  }

  static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    color.set()
    NSRect(origin: .zero, size: image.size).fill()
    image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .destinationIn, fraction: 1)
    out.unlockFocus()
    return out
  }

  // MARK: - Rendering

  @MainActor
  static func renderPanel(_ view: some View) -> NSImage? {
    let renderer = ImageRenderer(content: view.fixedSize(horizontal: false, vertical: true))
    renderer.scale = 2
    renderer.isOpaque = false
    return renderer.nsImage
  }

  static func write(_ image: NSImage, to path: String) {
    guard
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      print("encode failed: \(path)")
      return
    }
    try? png.write(to: URL(fileURLWithPath: path))
  }

  // MARK: - Contact sheets

  @MainActor
  static func contactSheet(
    light: [(DemoScene, NSImage)],
    dark: [(DemoScene, NSImage)],
    language: UILanguage
  ) -> NSImage? {
    let columns = 4
    let cellWidth: CGFloat = 384
    let cellHeight: CGFloat = 428
    let rows = (light.count + columns - 1) / columns + (dark.count + columns - 1) / columns
    let width = cellWidth * CGFloat(columns)
    let height = cellHeight * CGFloat(rows) + 44

    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width * 2),
        pixelsHigh: Int(height * 2),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return nil }
    bitmap.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(calibratedRed: 0.36, green: 0.37, blue: 0.39, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    drawTitle("dsh bar — \(language == .zhHans ? "中文" : "English")", at: NSPoint(x: 16, y: height - 30))

    var row = 0
    for (index, entry) in (light + dark).enumerated() {
      if index == light.count {
        row = (light.count + columns - 1) / columns
      }
      let localIndex = index < light.count ? index : index - light.count
      let column = localIndex % columns
      let cellRow = localIndex / columns
      let isDark = index >= light.count
      let cellX = CGFloat(column) * cellWidth
      let cellTop = height - 44 - CGFloat(row + cellRow) * cellHeight

      if column == 0 {
        NSColor(calibratedWhite: 0, alpha: 0.25).setFill()
        NSRect(x: 0, y: cellTop - cellHeight, width: width, height: 1).fill()
      }

      let image = entry.1
      let panelWidth = image.size.width
      let panelHeight = image.size.height
      let panelX = cellX + (cellWidth - panelWidth) / 2
      let panelY = cellTop - 24 - panelHeight

      let shadow = NSShadow()
      shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: isDark ? 0.5 : 0.28)
      shadow.shadowBlurRadius = 18
      shadow.shadowOffset = NSSize(width: 0, height: -8)
      NSGraphicsContext.saveGraphicsState()
      shadow.set()
      image.draw(in: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight))
      NSGraphicsContext.restoreGraphicsState()

      let label = "\(entry.0.title) · \(isDark ? "dark" : "light")"
      drawCaption(label, at: NSPoint(x: panelX, y: panelY - 16))
    }

    NSGraphicsContext.restoreGraphicsState()

    guard
      let tiff = bitmap.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { return nil }
    return NSImage(data: png)
  }

  static func drawTitle(_ text: String, at point: NSPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
      .foregroundColor: NSColor(calibratedWhite: 0.95, alpha: 1),
    ]
    NSAttributedString(string: text, attributes: attributes).draw(at: point)
  }

  static func drawCaption(_ text: String, at point: NSPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
      .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 0.85),
    ]
    NSAttributedString(string: text, attributes: attributes).draw(at: point)
  }
}
