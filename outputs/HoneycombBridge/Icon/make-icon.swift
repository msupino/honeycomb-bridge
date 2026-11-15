// Renders the app icon: an original honeycomb (hexagon) pattern. Usage: swift make-icon.swift out.png
import AppKit
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// Rounded square background
let bg = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(bg); ctx.clip()
let colors = [NSColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1).cgColor, NSColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1).cgColor] as CFArray
ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1])!, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
func hex(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<6 { let a = CGFloat(i) * .pi / 3; let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)); i == 0 ? p.move(to: pt) : p.addLine(to: pt) }
    p.closeSubpath(); return p
}
let r: CGFloat = 112, w = r * 1.5, h = r * sqrt(3)
let center = CGPoint(x: 512, y: 512)
// Centre + six neighbours (flat-top layout)
let cells: [(Int, Int)] = [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1), (1, -1), (-1, 1)]
for (i, (q, s)) in cells.enumerated() {
    let x = center.x + CGFloat(q) * w
    let y = center.y + (CGFloat(s) + CGFloat(q) / 2) * h
    let path = hex(CGPoint(x: x, y: y), r - 10)
    ctx.addPath(path)
    let fill = i == 0 ? NSColor(red: 0.98, green: 0.69, blue: 0.16, alpha: 1)
             : i == 3 ? NSColor(red: 0.25, green: 0.80, blue: 0.95, alpha: 0.95)
             : NSColor(red: 0.98, green: 0.69, blue: 0.16, alpha: 0.28 + 0.08 * CGFloat(i))
    ctx.setFillColor(fill.cgColor); ctx.fillPath()
    ctx.addPath(path); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor); ctx.setLineWidth(6); ctx.strokePath()
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
