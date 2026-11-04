#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Draws the app icon: the same ring-and-dot mark as the panel, on the plate
// colour, as a squircle. No binary assets in the repo.

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outRoot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconset = URL(fileURLWithPath: outRoot).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: Int) -> NSImage {
  let s = CGFloat(size)
  let image = NSImage(size: NSSize(width: s, height: s))
  image.lockFocus()
  guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

  let margin = s * 0.085
  let rect = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
  let radius = rect.width * 0.2237
  let plate = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

  ctx.saveGState()
  ctx.addPath(plate)
  ctx.setFillColor(CGColor(srgbRed: 0xFBFBFA / 255, green: 0xFBFBFA / 255, blue: 0xFA / 255, alpha: 1))
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(plate)
  ctx.setStrokeColor(CGColor(srgbRed: 0x0F / 255, green: 0x11 / 255, blue: 0x15 / 255, alpha: 0.10))
  ctx.setLineWidth(max(1, s * 0.004))
  ctx.strokePath()
  ctx.restoreGState()

  let ink = CGColor(srgbRed: 0xF / 255, green: 0x11 / 255, blue: 0x15 / 255, alpha: 1)
  let center = CGPoint(x: s / 2, y: s / 2)
  let ringRadius = s * 0.285
  let lineWidth = s * 0.028

  ctx.setStrokeColor(ink)
  ctx.setLineWidth(lineWidth)
  ctx.strokeEllipse(in: CGRect(
    x: center.x - ringRadius,
    y: center.y - ringRadius,
    width: ringRadius * 2,
    height: ringRadius * 2
  ))

  let dotRadius = ringRadius * 0.26
  ctx.setFillColor(ink)
  ctx.fillEllipse(in: CGRect(
    x: center.x - dotRadius,
    y: center.y - dotRadius,
    width: dotRadius * 2,
    height: dotRadius * 2
  ))

  image.unlockFocus()
  return image
}

for size in sizes {
  let image = draw(size: size)
  guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
  else { continue }
  try? png.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
  if size >= 32 {
    try? png.write(to: iconset.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png"))
  }
}
print("iconset written to \(iconset.path)")
