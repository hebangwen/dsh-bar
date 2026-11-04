import AppKit

/// Menu bar glyphs, drawn rather than bundled, so each state is legible as a
/// shape. Template images take their colour from the menu bar, so the shape has
/// to carry the meaning on its own.
///
/// Motion follows the same rule as the panel: only the two transitional states
/// move, plus a single pulse when the server comes up. A ring alone cannot show
/// rotation, so changing states use a three-quarter arc — clockwise while
/// starting, counter-clockwise while stopping.
public enum StatusIcon {
  /// Frames per revolution; 20 at 20 fps is one turn per second.
  public static let frameCount = 20

  public static func image(for phase: HarnessPhase, owner: ServerOwner) -> NSImage {
    icon { center in
      switch phase {
      case .unavailable:
        dashedRing(center: center, radius: 5.6, width: 1.5, dash: [1.4, 2.0])
      case .stopped:
        ring(center: center, radius: 5.6, width: 1.5)
      case .starting:
        arc(center: center, radius: 5.2, width: 1.6, start: 0, sweep: 265)
      case .listening:
        ring(center: center, radius: 5.6, width: 1.5)
        if owner == .external {
          ring(center: center, radius: 2.3, width: 1.4)
        } else {
          dot(center: center, radius: 2.4)
        }
      case .stopping:
        arc(center: center, radius: 5.2, width: 1.6, start: 0, sweep: 265)
      case .failed:
        ring(center: center, radius: 5.6, width: 1.5)
        slash(center: center, radius: 4.6, width: 1.6)
      }
    }
  }

  /// Frames a transitional glyph passes through. The app spins one static arc
  /// with Core Animation; these frames document that motion and are what the
  /// review sheets draw, so what is reviewed stays true to what ships.
  public static func frames(for phase: HarnessPhase, owner: ServerOwner) -> [NSImage]? {
    switch phase {
    case .starting:
      return (0..<frameCount).map { index in
        let start = Double(index) * 360 / Double(frameCount)
        return rasterized(icon { center in
          arc(center: center, radius: 5.2, width: 1.6, start: start, sweep: 265)
        })
      }
    case .stopping:
      return (0..<frameCount).map { index in
        let start = -Double(index) * 360 / Double(frameCount)
        return rasterized(icon { center in
          arc(center: center, radius: 5.2, width: 1.6, start: start, sweep: 265)
        })
      }
    case .unavailable, .stopped, .listening, .failed:
      return nil
    }
  }

  /// One short pulse when the server starts answering: the dot swells once and
  /// settles, so the arrival is noticed without anything moving afterwards.
  public static func arrivalPulse(for owner: ServerOwner) -> [NSImage] {
    let radii: [CGFloat] = [2.4, 2.9, 3.3, 3.5, 3.3, 2.9, 2.6, 2.4]
    return radii.map { radius in
      rasterized(icon { center in
        ring(center: center, radius: 5.6, width: 1.5)
        if owner == .external {
          ring(center: center, radius: radius, width: 1.5)
        } else {
          dot(center: center, radius: radius)
        }
      })
    }
  }

  // MARK: - Drawing

  private static func icon(_ body: @escaping (NSPoint) -> Void) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      let center = NSPoint(x: 9, y: 9)
      NSColor.black.setStroke()
      NSColor.black.setFill()
      body(center)
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "dsh bar"
    return image
  }

  /// Bakes a drawn frame into a 2x bitmap. An NSImage built from a drawing
  /// handler is re-rendered on every draw, which is far too expensive when the
  /// status item swaps frames twenty times a second.
  private static func rasterized(_ image: NSImage) -> NSImage {
    let points = NSSize(width: 18, height: 18)
    let scale = 2
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(points.width) * scale,
        pixelsHigh: Int(points.height) * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else { return image }
    rep.size = points
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: points))
    NSGraphicsContext.restoreGraphicsState()

    let baked = NSImage(size: points)
    baked.addRepresentation(rep)
    baked.isTemplate = true
    baked.accessibilityDescription = "dsh bar"
    return baked
  }

  private static func ring(center: NSPoint, radius: CGFloat, width: CGFloat) {
    let path = NSBezierPath(
      ovalIn: NSRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
      )
    )
    path.lineWidth = width
    path.stroke()
  }

  private static func dashedRing(center: NSPoint, radius: CGFloat, width: CGFloat, dash: [CGFloat]) {
    let path = NSBezierPath(
      ovalIn: NSRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
      )
    )
    path.lineWidth = width
    path.setLineDash(dash, count: dash.count, phase: 0)
    path.stroke()
  }

  /// An open arc: the gap is what makes rotation legible at 18pt.
  private static func arc(center: NSPoint, radius: CGFloat, width: CGFloat, start: Double, sweep: Double) {
    let path = NSBezierPath()
    path.appendArc(
      withCenter: center,
      radius: radius,
      startAngle: start,
      endAngle: start + sweep,
      clockwise: false
    )
    path.lineWidth = width
    path.lineCapStyle = .round
    path.stroke()
  }

  private static func dot(center: NSPoint, radius: CGFloat, alpha: CGFloat = 1) {
    NSColor.black.withAlphaComponent(alpha).setFill()
    NSBezierPath(
      ovalIn: NSRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
      )
    ).fill()
  }

  private static func slash(center: NSPoint, radius: CGFloat, width: CGFloat) {
    let path = NSBezierPath()
    let offset = radius * 0.7071
    path.move(to: NSPoint(x: center.x - offset, y: center.y - offset))
    path.line(to: NSPoint(x: center.x + offset, y: center.y + offset))
    path.lineWidth = width
    path.lineCapStyle = .round
    path.stroke()
  }
}
