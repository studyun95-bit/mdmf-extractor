import AppKit
let dir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (label, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
 let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
 NSGraphicsContext.saveGraphicsState()
 NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
 let scale = CGFloat(pixels) / 1024
 let transform = AffineTransform(scale: scale)
 (transform as NSAffineTransform).concat()
 NSColor(calibratedRed: 0.09, green: 0.24, blue: 0.56, alpha: 1).setFill()
 NSBezierPath(roundedRect: NSRect(x: 60,y: 60,width: 904,height: 904), xRadius: 205,yRadius: 205).fill()
 NSColor.white.setFill()
 NSBezierPath(roundedRect: NSRect(x: 268,y: 238,width: 488,height: 600), xRadius: 48,yRadius: 48).fill()
 let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 122, weight: .heavy), .foregroundColor: NSColor(calibratedRed: 0.09,green: 0.24,blue: 0.56,alpha: 1)]
 ("PDF" as NSString).draw(at: NSPoint(x: 392,y: 490), withAttributes: attr)
 NSColor(calibratedRed: 0.25,green: 0.81,blue: 0.75,alpha: 1).setStroke()
 let arrow = NSBezierPath()
 arrow.lineWidth = 44
 arrow.lineCapStyle = .round
 arrow.lineJoinStyle = .round
 arrow.move(to: NSPoint(x: 385,y: 400)); arrow.line(to: NSPoint(x: 638,y: 400))
 arrow.move(to: NSPoint(x: 560,y: 477)); arrow.line(to: NSPoint(x: 638,y: 400)); arrow.line(to: NSPoint(x: 560,y: 323)); arrow.stroke()
 NSGraphicsContext.restoreGraphicsState()
 try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/icon_\(label).png"))
}
