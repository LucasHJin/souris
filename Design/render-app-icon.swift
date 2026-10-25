// Renders AppIcon.svg into the phone app's icon PNGs: the icon itself, used in dark mode too, and
// a tinted version with a black background, which iOS colors by brightness.
//
// Run from the repository root: swift Design/render-app-icon.swift

import AppKit
import UniformTypeIdentifiers

let svg = try String(contentsOfFile: "Design/AppIcon.svg", encoding: .utf8)
let output = "SourisPhone/Assets.xcassets/AppIcon.appiconset"
let size = 1024

/// Draws `svg` into an opaque PNG at `name` in the icon set.
///
/// SVG images draw nothing into a bitmap without alpha, so it is drawn with alpha first and then
/// copied into an opaque one, as app icons must be.
func render(_ svg: String, to name: String) throws {
  guard let image = NSImage(data: Data(svg.utf8)),
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)
  else { throw CocoaError(.fileReadCorruptFile) }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
  NSGraphicsContext.restoreGraphicsState()

  guard let drawn = bitmap.cgImage,
    let opaque = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { throw CocoaError(.fileWriteUnknown) }
  opaque.draw(drawn, in: CGRect(x: 0, y: 0, width: size, height: size))
  let url = URL(fileURLWithPath: "\(output)/\(name)")
  guard let result = opaque.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { throw CocoaError(.fileWriteUnknown) }
  CGImageDestinationAddImage(destination, result, nil)
  guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

try render(svg, to: "AppIcon.png")
try render(
  svg.replacingOccurrences(of: "#2e2e2e", with: "#000000")
    .replacingOccurrences(of: "#373737", with: "#141414"),
  to: "AppIcon-Tinted.png")
