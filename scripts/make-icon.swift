// Draws Resources/AppIcon.icns: a record sliding out of a green sleeve.
// Run from the project folder: swift scripts/make-icon.swift
import AppKit

func draw(_ size: Int) -> CGImage {
    let s = CGFloat(size), u = s / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rgb = CGColorSpaceCreateDeviceRGB()
    // Background squircle (macOS icon grid: 824 pt inside 1024)
    let bg = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = CGPath(roundedRect: bg, cornerWidth: 185 * u, cornerHeight: 185 * u, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 24 * u, color: CGColor(gray: 0, alpha: 0.4))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: [CGColor(red: 0.2, green: 0.16, blue: 0.26, alpha: 1),
                                                                CGColor(red: 0.07, green: 0.06, blue: 0.09, alpha: 1)] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: 924 * u), end: CGPoint(x: 0, y: 100 * u), options: [])
    // Record
    let c = CGPoint(x: 600 * u, y: 512 * u), r = 270 * u
    ctx.setShadow(offset: CGSize(width: 6 * u, height: -8 * u), blur: 20 * u, color: CGColor(gray: 0, alpha: 0.6))
    ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    var gr = r * 0.4, i = 0
    while gr < r - 4 * u {
        ctx.setStrokeColor(CGColor(gray: 1, alpha: i % 3 == 0 ? 0.12 : 0.05)); ctx.setLineWidth(1.2 * u)
        ctx.strokeEllipse(in: CGRect(x: c.x - gr, y: c.y - gr, width: 2 * gr, height: 2 * gr))
        gr += 7 * u; i += 1
    }
    let lr = r * 0.36
    ctx.setFillColor(CGColor(red: 0.11, green: 0.73, blue: 0.33, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - lr, y: c.y - lr, width: 2 * lr, height: 2 * lr))
    ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - 12 * u, y: c.y - 12 * u, width: 24 * u, height: 24 * u))
    // Sleeve
    let sleeve = CGRect(x: 200 * u, y: 262 * u, width: 500 * u, height: 500 * u)
    ctx.setShadow(offset: CGSize(width: 10 * u, height: -10 * u), blur: 30 * u, color: CGColor(gray: 0, alpha: 0.55))
    ctx.addPath(CGPath(roundedRect: sleeve, cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil))
    ctx.setFillColor(CGColor(red: 0.11, green: 0.73, blue: 0.33, alpha: 1)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.addPath(CGPath(roundedRect: sleeve, cornerWidth: 14 * u, cornerHeight: 14 * u, transform: nil)); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: [CGColor(red: 0.2, green: 0.85, blue: 0.45, alpha: 1),
                                                                CGColor(red: 0.04, green: 0.35, blue: 0.17, alpha: 1)] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: sleeve.minX, y: sleeve.maxY), end: CGPoint(x: sleeve.maxX, y: sleeve.minY), options: [])
    // Three bars, like sound waves, on the sleeve
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
    for (k, h) in [150.0, 250.0, 190.0].enumerated() {
        let w = 46 * u, x = sleeve.midX - 110 * u + CGFloat(k) * 85 * u
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: sleeve.midY - CGFloat(h) * u / 2, width: w, height: CGFloat(h) * u),
                           cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
        ctx.fillPath()
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let data = NSBitmapImageRep(cgImage: draw(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run(); task.waitUntilExit()
try! NSBitmapImageRep(cgImage: draw(512)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/icon.png"))
print("Resources/AppIcon.icns")
