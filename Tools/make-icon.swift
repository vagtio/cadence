#!/usr/bin/env swift
// Draws the app icon and builds Resources/AppIcon.icns.
// Run: swift Tools/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

func makeIcon(size: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  defer { image.unlockFocus() }

  guard let context = NSGraphicsContext.current?.cgContext else { return image }
  let inset = size * 0.095
  let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
  let radius = size * 0.225

  let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
  context.saveGState()
  context.addPath(path)
  context.clip()

  // Base gradient: cool indigo → violet, the palette's accent family.
  let colors = [
    CGColor(red: 0.16, green: 0.40, blue: 0.98, alpha: 1),
    CGColor(red: 0.42, green: 0.20, blue: 0.92, alpha: 1),
  ] as CFArray
  if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: rect.minX, y: rect.maxY),
      end: CGPoint(x: rect.maxX, y: rect.minY),
      options: []
    )
  }

  // Soft top highlight so the tile reads as a physical surface.
  if let highlight = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.22), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
    locations: [0, 1]
  ) {
    context.drawLinearGradient(
      highlight,
      start: CGPoint(x: rect.midX, y: rect.maxY),
      end: CGPoint(x: rect.midX, y: rect.midY),
      options: []
    )
  }
  context.restoreGState()

  // Equaliser bars: the same motif the running app uses for its playing row,
  // so the icon reads as "this app" rather than "a music app".
  let barWidth = size * 0.115
  let gap = size * 0.072
  let heights: [CGFloat] = [0.30, 0.46, 0.36]
  let totalWidth = barWidth * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
  var x = (size - totalWidth) / 2
  let centreY = size / 2

  for (index, ratio) in heights.enumerated() {
    let height = size * ratio
    let rect = CGRect(x: x, y: centreY - height / 2, width: barWidth, height: height)
    let bar = CGPath(
      roundedRect: rect,
      cornerWidth: barWidth / 2,
      cornerHeight: barWidth / 2,
      transform: nil
    )
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.004),
                      blur: size * 0.02,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
    context.addPath(bar)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: index == 1 ? 0.98 : 0.82))
    context.fillPath()
    context.restoreGState()
    x += barWidth + gap
  }

  return image
}

func png(_ image: NSImage, size: CGFloat) -> Data? {
  guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
  ) else { return nil }
  rep.size = NSSize(width: size, height: size)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])
}

let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = makeIcon(size: 1024)
if let data = png(master, size: 1024) {
  try? data.write(to: resources.appendingPathComponent("icon-1024.png"))
}

for base in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = base * scale
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    if let data = png(makeIcon(size: CGFloat(pixels)), size: CGFloat(pixels)) {
      try? data.write(to: iconset.appendingPathComponent(name))
    }
  }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try? process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "icon ok" : "iconutil failed")
