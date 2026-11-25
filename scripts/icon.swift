// Draws the app icon: a monkey's face on a keycap. Usage: swift icon.swift out.iconset
import AppKit
let out = URL(filePath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let t = NSAffineTransform(); t.scale(by: CGFloat(px) / 1024); t.concat()
    func rounded(_ r: NSRect, _ radius: CGFloat, _ top: NSColor, _ bottom: NSColor) {
        NSGradient(starting: bottom, ending: top)!.draw(in: NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius), angle: 90)
    }
    func c(_ h: Int) -> NSColor { NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }
    func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Int) {   // x, y is the middle
        c(color).setFill(); NSBezierPath(ovalIn: NSRect(x: x - w / 2, y: y - h / 2, width: w, height: h)).fill()
    }
    rounded(NSRect(x: 100, y: 100, width: 824, height: 824), 185, c(0xFFD84D), c(0xF7A928))   // plate
    for x in [242, 782] as [CGFloat] { oval(x, 540, 190, 200, 0x6B3F24); oval(x, 540, 108, 118, 0xF2C79B) }   // ears
    rounded(NSRect(x: 232, y: 196, width: 560, height: 600), 130, c(0x5A3219), c(0x43230F))   // keycap skirt
    rounded(NSRect(x: 272, y: 282, width: 480, height: 478), 110, c(0x8A5633), c(0x734526))   // keycap top
    oval(430, 572, 190, 210, 0xF6D3AC); oval(594, 572, 190, 210, 0xF6D3AC); oval(512, 432, 330, 250, 0xF6D3AC)   // face
    oval(436, 572, 58, 84, 0x2B170B); oval(588, 572, 58, 84, 0x2B170B)
    oval(446, 594, 18, 24, 0xFFFFFF); oval(598, 594, 18, 24, 0xFFFFFF)
    oval(490, 474, 16, 20, 0x6B3F24); oval(534, 474, 16, 20, 0x6B3F24)
    oval(512, 392, 92, 96, 0x7A2B24); oval(512, 372, 56, 40, 0xE8776B)   // an "oh!" mouth
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for s in [16, 32, 128, 256, 512] {
    try draw(s).write(to: out.appending(path: "icon_\(s)x\(s).png"))
    try draw(s * 2).write(to: out.appending(path: "icon_\(s)x\(s)@2x.png"))
}
