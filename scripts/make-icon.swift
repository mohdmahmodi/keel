import AppKit
// Renders a flat icon: dark rounded square, white keel glyph (sailboat SF Symbol).
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let dir = "Resources/Keel.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for s in sizes {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let r = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: CGFloat(s) * 0.04, dy: CGFloat(s) * 0.04)
    NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.13, alpha: 1).setFill()
    NSBezierPath(roundedRect: r, xRadius: CGFloat(s) * 0.22, yRadius: CGFloat(s) * 0.22).fill()
    NSColor(calibratedWhite: 1, alpha: 0.10).setStroke()
    let b = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: CGFloat(s) * 0.22, yRadius: CGFloat(s) * 0.22); b.lineWidth = max(1, CGFloat(s) / 128); b.stroke()
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(s) * 0.5, weight: .medium)
    if let sym = NSImage(systemSymbolName: "sailboat", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size, flipped: false) { rect in
            sym.draw(in: rect); NSColor(calibratedWhite: 0.95, alpha: 1).set(); rect.fill(using: .sourceAtop); return true }
        let sz = tinted.size
        tinted.draw(in: NSRect(x: (CGFloat(s) - sz.width) / 2, y: (CGFloat(s) - sz.height) / 2, width: sz.width, height: sz.height))
    }
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = s <= 512 ? "icon_\(s)x\(s).png" : "icon_512x512@2x.png"
    try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    if s >= 32 && s <= 512 { try? png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(s/2)x\(s/2)@2x.png")) }
}
print("iconset written")
