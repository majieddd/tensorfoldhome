// Renders TensorFold Home's icon: a 3x3 grid of emerald cells (a tensor) whose top-right cell is folded over.
//   swift tools/make_icon.swift assets/icon-1024.png
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// the tile (Apple's icon grid: 824 px body, 185 px corners), the night palette's background
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSGradient(colors: [color(0x1D2226), color(0x0E1113)])!.draw(in: tile, angle: -90)
ctx.restoreGState()
color(0xFFFFFF, 0.06).setStroke()
tile.lineWidth = 4
tile.stroke()

// the grid: 3 x 3 cells of 160 px with 40 px gaps, centred
let cell: CGFloat = 160, gap: CGFloat = 40
let origin = (size - (cell * 3 + gap * 2)) / 2
let shades: [UInt32] = [0x10B981, 0x34D399, 0x10B981, 0x34D399, 0x10B981, 0x34D399, 0x10B981, 0x34D399]
var k = 0
for row in 0..<3 {
    for col in 0..<3 {
        let r = NSRect(x: origin + CGFloat(col) * (cell + gap), y: origin + CGFloat(row) * (cell + gap), width: cell, height: cell)
        if row == 2 && col == 2 {
            // the folded cell: the lower-left half stays, the upper-right half is folded down over it
            let stay = NSBezierPath()
            stay.move(to: NSPoint(x: r.minX + 36, y: r.minY))
            stay.line(to: NSPoint(x: r.maxX - 36, y: r.minY))
            stay.curve(to: NSPoint(x: r.maxX, y: r.minY + 36), controlPoint1: NSPoint(x: r.maxX - 16, y: r.minY), controlPoint2: NSPoint(x: r.maxX, y: r.minY + 16))
            stay.line(to: NSPoint(x: r.minX, y: r.maxY))
            stay.line(to: NSPoint(x: r.minX, y: r.minY + 36))
            stay.curve(to: NSPoint(x: r.minX + 36, y: r.minY), controlPoint1: NSPoint(x: r.minX, y: r.minY + 16), controlPoint2: NSPoint(x: r.minX + 16, y: r.minY))
            stay.close()
            color(0x0C8A60).setFill()
            stay.fill()
            let flap = NSBezierPath()
            flap.move(to: NSPoint(x: r.minX, y: r.maxY))
            flap.line(to: NSPoint(x: r.maxX, y: r.minY + 36))
            flap.line(to: NSPoint(x: r.minX + 24, y: r.minY + 24))
            flap.close()
            ctx.saveGState()
            let s2 = NSShadow()
            s2.shadowColor = NSColor.black.withAlphaComponent(0.45)
            s2.shadowBlurRadius = 18
            s2.shadowOffset = NSSize(width: 6, height: -8)
            s2.set()
            NSGradient(colors: [color(0xD1FAE5), color(0x6EE7B7)])!.draw(in: flap, angle: -45)
            ctx.restoreGState()
            continue
        }
        let p = NSBezierPath(roundedRect: r, xRadius: 36, yRadius: 36)
        color(shades[k % shades.count]).setFill()
        p.fill()
        k += 1
    }
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
