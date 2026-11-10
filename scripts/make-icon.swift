// Genera Resources/tunnelbar-logo.png (1024x1024): escudo con candado.
// Uso: swift scripts/make-icon.swift Resources/tunnelbar-logo.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "Resources/tunnelbar-logo.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Escudo
let shield = NSBezierPath()
shield.move(to: NSPoint(x: 512, y: 960))
shield.curve(to: NSPoint(x: 120, y: 820), controlPoint1: NSPoint(x: 380, y: 880), controlPoint2: NSPoint(x: 240, y: 840))
shield.curve(to: NSPoint(x: 512, y: 60), controlPoint1: NSPoint(x: 110, y: 420), controlPoint2: NSPoint(x: 260, y: 200))
shield.curve(to: NSPoint(x: 904, y: 820), controlPoint1: NSPoint(x: 764, y: 200), controlPoint2: NSPoint(x: 914, y: 420))
shield.curve(to: NSPoint(x: 512, y: 960), controlPoint1: NSPoint(x: 784, y: 840), controlPoint2: NSPoint(x: 644, y: 880))
shield.close()
NSGradient(starting: NSColor(red: 0.18, green: 0.55, blue: 0.98, alpha: 1),
           ending: NSColor(red: 0.29, green: 0.20, blue: 0.85, alpha: 1))!.draw(in: shield, angle: -90)

// Candado
NSColor.white.setStroke(); NSColor.white.setFill()
let shackle = NSBezierPath()
shackle.lineWidth = 56
shackle.appendArc(withCenter: NSPoint(x: 512, y: 560), radius: 120, startAngle: 0, endAngle: 180)
shackle.move(to: NSPoint(x: 392, y: 560)); shackle.line(to: NSPoint(x: 392, y: 500))
shackle.move(to: NSPoint(x: 632, y: 560)); shackle.line(to: NSPoint(x: 632, y: 500))
shackle.stroke()
NSBezierPath(roundedRect: NSRect(x: 322, y: 250, width: 380, height: 280), xRadius: 48, yRadius: 48).fill()
NSColor(red: 0.25, green: 0.33, blue: 0.90, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 477, y: 400, width: 70, height: 70)).fill()
NSBezierPath(roundedRect: NSRect(x: 494, y: 310, width: 36, height: 110), xRadius: 18, yRadius: 18).fill()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Icono generado: \(out)")
