#!/usr/bin/env swift
// Screenshot helper for the README.
//
//   crop <in> <out> top <pixels> [maxWidth]        crop N px off the top
//   crop <in> <out> split <leftWidth> <top> [max]  keep the left column full height,
//                                                  crop the top off the right column
//
// "split" exists because the window toolbar area is not part of the offscreen
// capture: it shows up as an empty band over the detail pane only.
import AppKit

func writeJPEG(_ cg: CGImage, to path: String, maxWidth: Int?) {
  var image = cg
  if let maxWidth, cg.width > maxWidth {
    let scale = CGFloat(maxWidth) / CGFloat(cg.width)
    let target = CGSize(width: CGFloat(maxWidth), height: CGFloat(cg.height) * scale)
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: cg, size: .zero).draw(in: NSRect(origin: .zero, size: target))
    NSGraphicsContext.restoreGraphicsState()
    image = rep.cgImage!
  }
  let data = NSBitmapImageRep(cgImage: image)
    .representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
  try! data.write(to: URL(fileURLWithPath: path))
  print("wrote \(path) \(image.width)x\(image.height) \(data.count / 1024) KB")
}

let args = CommandLine.arguments
guard args.count >= 5,
      let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
  print("usage: crop <in> <out> top <px> [maxWidth] | split <leftWidth> <top> [maxWidth]")
  exit(2)
}

switch args[3] {
case "top":
  let top = Int(args[4]) ?? 0
  guard let cropped = cg.cropping(to: CGRect(x: 0, y: top, width: cg.width, height: cg.height - top)) else { exit(1) }
  writeJPEG(cropped, to: args[2], maxWidth: args.count > 5 ? Int(args[5]) : nil)

case "split":
  guard args.count >= 6, let leftWidth = Int(args[4]), let top = Int(args[5]) else { exit(2) }
  let left = cg.cropping(to: CGRect(x: 0, y: 0, width: leftWidth, height: cg.height))!
  let right = cg.cropping(to: CGRect(x: leftWidth, y: top, width: cg.width - leftWidth, height: cg.height - top))!
  let width = left.width + right.width
  let height = max(left.height, right.height)
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
  )!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSImage(cgImage: left, size: .zero).draw(in: NSRect(x: 0, y: 0, width: left.width, height: left.height))
  // AppKit's origin is bottom-left: top-align the shorter (cropped) column.
  let rightY = Int(left.height - right.height)
  NSImage(cgImage: right, size: .zero).draw(in: NSRect(x: leftWidth, y: rightY, width: right.width, height: right.height))
  NSGraphicsContext.restoreGraphicsState()
  writeJPEG(rep.cgImage!, to: args[2], maxWidth: args.count > 6 ? Int(args[6]) : nil)

default:
  print("unknown mode \(args[3])")
  exit(2)
}
