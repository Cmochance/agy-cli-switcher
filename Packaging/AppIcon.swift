import AppKit

// 画 Agy Switcher 的图标并生成 icns。换图标时改这里，然后在仓库根目录执行：
//   swift Packaging/AppIcon.swift Packaging/AppIcon.icns
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

func drawShadowed(_ path: NSBezierPath, color: NSColor, blur: CGFloat, offset: NSSize, scale: CGFloat, draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur * scale
    shadow.shadowOffset = NSSize(width: offset.width * scale, height: offset.height * scale)
    shadow.set()
    NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    draw()
    NSGraphicsContext.current?.cgContext.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()
}

func drawArrow(from start: NSPoint, to end: NSPoint, headSize: CGFloat, width: CGFloat, color: NSColor) {
    let dir: CGFloat = end.x > start.x ? -1 : 1
    let arrow = NSBezierPath()
    arrow.lineWidth = width
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: start)
    arrow.line(to: end)
    arrow.move(to: NSPoint(x: end.x + dir * headSize, y: end.y + headSize))
    arrow.line(to: end)
    arrow.line(to: NSPoint(x: end.x + dir * headSize, y: end.y - headSize))
    color.setStroke()
    arrow.stroke()
}

func antigravityArchPath(in box: NSRect) -> NSBezierPath {
    func pt(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
        NSPoint(x: box.minX + u * box.width, y: box.minY + v * box.height)
    }
    let path = NSBezierPath()
    path.move(to: pt(0.08, 0.13))
    path.curve(to: pt(0.50, 0.94), controlPoint1: pt(0.24, 0.34), controlPoint2: pt(0.32, 0.94))
    path.curve(to: pt(0.92, 0.13), controlPoint1: pt(0.68, 0.94), controlPoint2: pt(0.76, 0.34))
    path.curve(to: pt(0.81, 0.06), controlPoint1: pt(0.96, 0.07), controlPoint2: pt(0.87, 0.02))
    path.curve(to: pt(0.50, 0.44), controlPoint1: pt(0.71, 0.12), controlPoint2: pt(0.64, 0.44))
    path.curve(to: pt(0.19, 0.06), controlPoint1: pt(0.36, 0.44), controlPoint2: pt(0.29, 0.12))
    path.curve(to: pt(0.08, 0.13), controlPoint1: pt(0.13, 0.02), controlPoint2: pt(0.04, 0.07))
    path.close()
    return path
}

func drawAntigravityArch(in box: NSRect, colorful: Bool, scale: CGFloat) {
    let arch = antigravityArchPath(in: box)
    guard colorful else {
        NSColor(srgbRed: 0.88, green: 0.96, blue: 1.0, alpha: 0.85).setFill()
        arch.fill()
        return
    }
    func pt(_ u: CGFloat, _ v: CGFloat) -> NSPoint {
        NSPoint(x: box.minX + u * box.width, y: box.minY + v * box.height)
    }
    let baseGradient = NSGradient(
        colors: [
            NSColor(srgbRed: 0.18, green: 0.49, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.26, green: 0.56, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.98, green: 0.68, blue: 0.12, alpha: 1),
        ],
        atLocations: [0.0, 0.55, 1.0],
        colorSpace: .sRGB
    )!
    let glows: [(NSPoint, CGFloat, NSColor)] = [
        (pt(0.26, 0.62), 0.52, NSColor(srgbRed: 0.20, green: 0.74, blue: 0.38, alpha: 0.94)),
        (pt(0.42, 0.88), 0.45, NSColor(srgbRed: 0.99, green: 0.78, blue: 0.10, alpha: 0.96)),
        (pt(0.66, 0.76), 0.54, NSColor(srgbRed: 0.95, green: 0.30, blue: 0.22, alpha: 0.96)),
        (pt(0.50, 0.30), 0.56, NSColor(srgbRed: 0.16, green: 0.48, blue: 0.98, alpha: 0.95)),
    ]
    drawShadowed(arch, color: NSColor(srgbRed: 0.08, green: 0.14, blue: 0.42, alpha: 0.22), blur: 12, offset: NSSize(width: 0, height: -5), scale: scale) {
        NSGraphicsContext.saveGraphicsState()
        arch.addClip()
        baseGradient.draw(in: arch, angle: 90)
        for (center, radiusRatio, color) in glows {
            NSGradient(starting: color, ending: color.withAlphaComponent(0))!.draw(
                fromCenter: center,
                radius: 0,
                toCenter: center,
                radius: radiusRatio * box.width,
                options: []
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

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

    // 1. 底层圆角底板：多段深邃蓝紫对角渐变 + 双色环境光晕 + 内圈微光描边。
    let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    let plateGradient = NSGradient(
        colors: [
            NSColor(srgbRed: 0.20, green: 0.32, blue: 0.90, alpha: 1),
            NSColor(srgbRed: 0.12, green: 0.15, blue: 0.56, alpha: 1),
            NSColor(srgbRed: 0.06, green: 0.07, blue: 0.26, alpha: 1),
        ],
        atLocations: [0.0, 0.5, 1.0],
        colorSpace: .sRGB
    )!
    drawShadowed(plate, color: NSColor(srgbRed: 0.04, green: 0.05, blue: 0.18, alpha: 0.38), blur: 28, offset: NSSize(width: 0, height: -14), scale: scale) {
        plateGradient.draw(in: plate, angle: -65)
    }
    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    NSGradient(
        starting: NSColor(srgbRed: 0.22, green: 0.82, blue: 1.0, alpha: 0.42),
        ending: NSColor(srgbRed: 0.22, green: 0.82, blue: 1.0, alpha: 0)
    )!.draw(fromCenter: NSPoint(x: 230, y: 800), radius: 0, toCenter: NSPoint(x: 230, y: 800), radius: 520, options: [])
    NSGradient(
        starting: NSColor(srgbRed: 0.66, green: 0.22, blue: 0.94, alpha: 0.36),
        ending: NSColor(srgbRed: 0.66, green: 0.22, blue: 0.94, alpha: 0)
    )!.draw(fromCenter: NSPoint(x: 790, y: 210), radius: 0, toCenter: NSPoint(x: 790, y: 210), radius: 500, options: [])
    plate.lineWidth = 8
    NSColor.white.withAlphaComponent(0.22).setStroke()
    plate.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // 2. 第三层远景幽灵卡：拉开多账号叠放的空间纵深。
    let ghostCard = NSBezierPath(roundedRect: NSRect(x: 168, y: 492, width: 432, height: 320), xRadius: 68, yRadius: 68)
    NSGradient(
        starting: NSColor(srgbRed: 0.48, green: 0.36, blue: 0.96, alpha: 0.34),
        ending: NSColor(srgbRed: 0.24, green: 0.22, blue: 0.72, alpha: 0.22)
    )!.draw(in: ghostCard, angle: -90)
    ghostCard.lineWidth = 6
    NSColor(srgbRed: 0.68, green: 0.74, blue: 1.0, alpha: 0.28).setStroke()
    ghostCard.stroke()

    // 3. 中层备用账号卡（左上）：天蓝到靛青渐变玻璃卡面。
    let middleCard = NSBezierPath(roundedRect: NSRect(x: 214, y: 420, width: 468, height: 348), xRadius: 74, yRadius: 74)
    let middleGradient = NSGradient(
        colors: [
            NSColor(srgbRed: 0.30, green: 0.66, blue: 0.98, alpha: 0.92),
            NSColor(srgbRed: 0.24, green: 0.42, blue: 0.90, alpha: 0.90),
            NSColor(srgbRed: 0.22, green: 0.26, blue: 0.76, alpha: 0.90),
        ],
        atLocations: [0.0, 0.55, 1.0],
        colorSpace: .sRGB
    )!
    drawShadowed(middleCard, color: NSColor(srgbRed: 0.03, green: 0.04, blue: 0.20, alpha: 0.35), blur: 20, offset: NSSize(width: 0, height: -10), scale: scale) {
        middleGradient.draw(in: middleCard, angle: -95)
    }
    middleCard.lineWidth = 7
    NSColor(srgbRed: 0.72, green: 0.90, blue: 1.0, alpha: 0.55).setStroke()
    middleCard.stroke()

    // 中层卡顶部露出的 Antigravity A 徽标、账号名条与套餐胶囊。
    drawAntigravityArch(in: NSRect(x: 262, y: 656, width: 58, height: 60), colorful: false, scale: scale)
    NSColor(srgbRed: 0.85, green: 0.95, blue: 1.0, alpha: 0.62).setFill()
    NSBezierPath(roundedRect: NSRect(x: 336, y: 673, width: 204, height: 26), xRadius: 13, yRadius: 13).fill()
    NSColor(srgbRed: 0.72, green: 0.88, blue: 1.0, alpha: 0.42).setFill()
    NSBezierPath(roundedRect: NSRect(x: 558, y: 673, width: 66, height: 26), xRadius: 13, yRadius: 13).fill()

    // 4. 前景当前账号卡（右下）：珍珠白到冰蓝渐变 + 强投影 + Antigravity 四色 A 标志与双向切换箭头。
    let frontCard = NSBezierPath(roundedRect: NSRect(x: 334, y: 216, width: 486, height: 374), xRadius: 78, yRadius: 78)
    let frontGradient = NSGradient(
        colors: [
            NSColor(srgbRed: 0.99, green: 1.00, blue: 1.00, alpha: 0.99),
            NSColor(srgbRed: 0.92, green: 0.96, blue: 1.00, alpha: 0.98),
            NSColor(srgbRed: 0.82, green: 0.90, blue: 1.00, alpha: 0.97),
        ],
        atLocations: [0.0, 0.6, 1.0],
        colorSpace: .sRGB
    )!
    drawShadowed(frontCard, color: NSColor(srgbRed: 0.02, green: 0.03, blue: 0.16, alpha: 0.52), blur: 34, offset: NSSize(width: -8, height: -16), scale: scale) {
        frontGradient.draw(in: frontCard, angle: -100)
    }
    frontCard.lineWidth = 8
    NSColor.white.withAlphaComponent(0.95).setStroke()
    frontCard.stroke()

    NSColor(srgbRed: 0.14, green: 0.19, blue: 0.56, alpha: 0.88).setFill()
    NSBezierPath(roundedRect: NSRect(x: 384, y: 502, width: 274, height: 26), xRadius: 13, yRadius: 13).fill()
    let tierPill = NSBezierPath(roundedRect: NSRect(x: 678, y: 502, width: 88, height: 26), xRadius: 13, yRadius: 13)
    NSGradient(
        starting: NSColor(srgbRed: 0.99, green: 0.72, blue: 0.14, alpha: 0.96),
        ending: NSColor(srgbRed: 0.94, green: 0.32, blue: 0.24, alpha: 0.96)
    )!.draw(in: tierPill, angle: -20)

    // 左侧为 Google 四色渐变 Antigravity 标志，右侧为双向切换箭头。
    drawAntigravityArch(in: NSRect(x: 372, y: 266, width: 188, height: 198), colorful: true, scale: scale)
    drawArrow(
        from: NSPoint(x: 588, y: 412),
        to: NSPoint(x: 756, y: 412),
        headSize: 38,
        width: 34,
        color: NSColor(srgbRed: 0.18, green: 0.24, blue: 0.78, alpha: 0.96)
    )
    drawArrow(
        from: NSPoint(x: 756, y: 304),
        to: NSPoint(x: 588, y: 304),
        headSize: 38,
        width: 34,
        color: NSColor(srgbRed: 0.06, green: 0.64, blue: 0.86, alpha: 0.96)
    )
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
