// Draws the LifeBoard artwork with a "Preview" band so the two apps are
// distinguishable in the Dock and Finder. Usage: swift preview-icon.swift <in.png> <out.png>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let source = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: preview-icon.swift <in.png> <out.png>\n".utf8)); exit(1)
}
let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
source.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
// A lamp-coloured band across the lower part of the rounded square.
let band = NSRect(x: 214, y: 120, width: 596, height: 132)
NSColor(srgbRed: 0.949, green: 0.843, blue: 0.651, alpha: 1).setFill()
NSBezierPath(roundedRect: band, xRadius: 66, yRadius: 66).fill()
let label = "Preview" as NSString
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 92, weight: .semibold),
    .foregroundColor: NSColor(srgbRed: 0.118, green: 0.169, blue: 0.235, alpha: 1)
]
let measured = label.size(withAttributes: attributes)
label.draw(at: NSPoint(x: band.midX - measured.width / 2, y: band.midY - measured.height / 2 + 4), withAttributes: attributes)
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[2]))
