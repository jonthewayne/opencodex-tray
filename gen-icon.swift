import AppKit

// Renders the app icon master PNG. Usage: gen-icon <out.png>
let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// rounded-rect background with a teal→blue gradient
let rect = NSRect(x: 0, y: 0, width: S, height: S)
NSBezierPath(roundedRect: rect, xRadius: S * 0.2237, yRadius: S * 0.2237).addClip()
NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.62, blue: 0.58, alpha: 1),
                    NSColor(srgbRed: 0.13, green: 0.33, blue: 0.80, alpha: 1)])!
    .draw(in: rect, angle: -90)

// white "arrow.triangle.swap" glyph (routing), centered
let cfg = NSImage.SymbolConfiguration(pointSize: 400, weight: .semibold)
if let base = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil),
   let sym = base.withSymbolConfiguration(cfg) {
    let gs = sym.size
    let tinted = NSImage(size: gs)
    tinted.lockFocus()
    sym.draw(at: .zero, from: NSRect(origin: .zero, size: gs), operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: gs).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let box = S * 0.66
    let scale = min(box / gs.width, box / gs.height)
    let w = gs.width * scale, h = gs.height * scale
    tinted.draw(in: NSRect(x: (S - w) / 2, y: (S - h) / 2, width: w, height: h))
}
img.unlockFocus()

if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}
