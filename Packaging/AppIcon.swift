import AppKit

// 画 Agy Switcher 的图标并生成 icns。换图标时改这里，然后在仓库根目录执行：
//   swift Packaging/AppIcon.swift Packaging/AppIcon.icns
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func picture(pixels: Int) -> Data {
    let canvas = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    canvas.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
    // 下面的坐标都按 1024 的画布写。
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    shadow.set()
    NSColor(srgbRed: 0.16, green: 0.18, blue: 0.70, alpha: 1).setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(
        starting: NSColor(srgbRed: 0.42, green: 0.49, blue: 1.0, alpha: 1),
        ending: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.70, alpha: 1)
    )!.draw(in: plate, angle: -90)

    // 上面一支箭头朝右，下面一支朝左：换一个账号。
    let arrows = NSBezierPath()
    arrows.lineWidth = 64
    arrows.lineCapStyle = .round
    arrows.lineJoinStyle = .round
    arrows.move(to: NSPoint(x: 330, y: 612))
    arrows.line(to: NSPoint(x: 694, y: 612))
    arrows.move(to: NSPoint(x: 618, y: 688))
    arrows.line(to: NSPoint(x: 694, y: 612))
    arrows.line(to: NSPoint(x: 618, y: 536))
    arrows.move(to: NSPoint(x: 694, y: 412))
    arrows.line(to: NSPoint(x: 330, y: 412))
    arrows.move(to: NSPoint(x: 406, y: 488))
    arrows.line(to: NSPoint(x: 330, y: 412))
    arrows.line(to: NSPoint(x: 406, y: 336))
    NSColor.white.setStroke()
    arrows.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return canvas.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try picture(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try picture(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", "-o", output, iconset.path]
try tool.run()
tool.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(tool.terminationStatus)
