// Renders the app icon: a blue rounded square with a monitor glyph, a green status dot,
// and a connection line. Writes the 1024px master; make-icon.sh scales the rest.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = size * 0.10          // macOS icons leave a margin around the tile
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.width * 0.22)

// Background gradient
tilePath.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.95, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.20, blue: 0.60, alpha: 1),
])!
gradient.draw(in: tile, angle: -90)

// Soft highlight band
ctx.saveGState()
NSColor.white.withAlphaComponent(0.08).setFill()
NSBezierPath(ovalIn: CGRect(x: tile.minX - tile.width * 0.2, y: tile.midY, width: tile.width * 1.4, height: tile.height * 0.9)).fill()
ctx.restoreGState()

// Monitor
let monW = tile.width * 0.60, monH = tile.height * 0.40
let monRect = CGRect(x: tile.midX - monW / 2, y: tile.midY - monH * 0.15, width: monW, height: monH)
let bezel = NSBezierPath(roundedRect: monRect, xRadius: monW * 0.06, yRadius: monW * 0.06)
NSColor.white.setFill()
bezel.fill()
let screen = monRect.insetBy(dx: monW * 0.045, dy: monW * 0.045)
NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.40, alpha: 1).setFill()
NSBezierPath(roundedRect: screen, xRadius: monW * 0.03, yRadius: monW * 0.03).fill()

// Stand
let standW = monW * 0.12, standH = monH * 0.18
NSColor.white.setFill()
NSBezierPath(rect: CGRect(x: tile.midX - standW / 2, y: monRect.minY - standH, width: standW, height: standH)).fill()
let baseW = monW * 0.42, baseH = monH * 0.07
NSBezierPath(roundedRect: CGRect(x: tile.midX - baseW / 2, y: monRect.minY - standH - baseH, width: baseW, height: baseH),
             xRadius: baseH / 2, yRadius: baseH / 2).fill()

// Connection line: dot at the bottom, line up into the stand
let dotR = tile.width * 0.045
let dotCenter = CGPoint(x: tile.midX, y: tile.minY + tile.height * 0.14)
let line = NSBezierPath()
line.move(to: CGPoint(x: tile.midX, y: dotCenter.y + dotR))
line.line(to: CGPoint(x: tile.midX, y: monRect.minY - standH - baseH))
line.lineWidth = tile.width * 0.022
line.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.85).setStroke()
line.stroke()
NSColor.white.setFill()
NSBezierPath(ovalIn: CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2)).fill()

// Green "online" status dot on the screen
let statusR = monW * 0.07
NSColor(calibratedRed: 0.20, green: 0.84, blue: 0.40, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(x: screen.maxX - statusR * 2.6, y: screen.maxY - statusR * 2.6,
                            width: statusR * 2, height: statusR * 2)).fill()

image.unlockFocus()

let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
rep.size = NSSize(width: size, height: size)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
