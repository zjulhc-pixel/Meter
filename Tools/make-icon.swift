// Renders Meter's app icon: a 12-segment usage ring whose lit segments glow violet.
//
//   swift Tools/make-icon.swift <style> Resources/AppIcon.icns   # build the .icns
//   swift Tools/make-icon.swift <style> preview.png              # 1024px PNG only
//   swift Tools/make-icon.swift sheet styles.png                 # all styles side by side
//
// Styles: flat, aluminum, titanium, glass, obsidian
import AppKit

let canvas: CGFloat = 1024
let center = CGPoint(x: 512, y: 512)
let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let plateRadius: CGFloat = 186
let segments = 12, lit = 8
let wellRadius: CGFloat = 318, innerRadius: CGFloat = 150, outerRadius: CGFloat = 292, discRadius: CGFloat = 118
let styles = ["flat", "aluminum", "titanium", "glass", "obsidian"]

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
func white(_ alpha: CGFloat) -> CGColor { CGColor(gray: 1, alpha: alpha) }
func black(_ alpha: CGFloat) -> CGColor { CGColor(gray: 0, alpha: alpha) }
func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}
let violet = rgb(0x785CFF)

// MARK: - Geometry

func circle(_ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
}

let platePath = CGPath(roundedRect: plateRect, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil)

/// Annular sector (degrees, counter-clockwise from 3 o'clock) with rounded corners:
/// an inset sector unioned with its own round-joined stroke.
func segmentPath(_ index: Int) -> CGPath {
    let step = 360 / CGFloat(segments), gap: CGFloat = 8, rounding: CGFloat = 26
    let start = (90 - CGFloat(index) * step - gap / 2) * .pi / 180
    let end = start - (step - gap) * .pi / 180
    let inset = rounding / 2
    let angularInset = inset / ((innerRadius + outerRadius) / 2)
    let core = CGMutablePath()
    core.addArc(center: center, radius: outerRadius - inset, startAngle: start - angularInset, endAngle: end + angularInset, clockwise: true)
    core.addArc(center: center, radius: innerRadius + inset, startAngle: end + angularInset, endAngle: start - angularInset, clockwise: false)
    core.closeSubpath()
    return core.union(core.copy(strokingWithWidth: rounding, lineCap: .round, lineJoin: .round, miterLimit: 10))
}

// MARK: - Drawing helpers

extension CGContext {
    func clipped(to path: CGPath, _ body: () -> Void) {
        saveGState(); addPath(path); clip(); body(); restoreGState()
    }

    func fill(_ path: CGPath, _ color: CGColor) {
        addPath(path); setFillColor(color); fillPath()
    }

    func linear(_ g: CGGradient, from: CGPoint, to: CGPoint) {
        drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    func radial(_ g: CGGradient, at point: CGPoint, from r0: CGFloat = 0, to r1: CGFloat) {
        drawRadialGradient(g, startCenter: point, startRadius: r0, endCenter: point, endRadius: r1,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Angular (conic) gradient around `point`, built from thin wedges; `stops` run 0…1 counter-clockwise from `angle`.
    func conic(_ stops: [(CGColor, CGFloat)], at point: CGPoint, angle: CGFloat, radius: CGFloat = 1500) {
        func components(_ c: CGColor) -> [CGFloat] { c.converted(to: sRGB, intent: .defaultIntent, options: nil)!.components! }
        let steps = 720
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            let upper = stops.firstIndex { $0.1 >= t } ?? stops.count - 1
            let lower = max(upper - 1, 0)
            let span = stops[upper].1 - stops[lower].1
            let f = span > 0 ? (t - stops[lower].1) / span : 0
            let a = components(stops[lower].0), b = components(stops[upper].0)
            let mixed = zip(a, b).map { $0 + ($1 - $0) * f }
            let wedge = CGMutablePath()
            wedge.move(to: point)
            wedge.addArc(center: point, radius: radius, startAngle: angle + t * 2 * .pi,
                         endAngle: angle + (t + 1.5 / CGFloat(steps)) * 2 * .pi, clockwise: false)
            wedge.closeSubpath()
            fill(wedge, CGColor(colorSpace: sRGB, components: mixed)!)
        }
    }

    /// Gradient applied along a stroke of `path`.
    func stroke(_ path: CGPath, width: CGFloat, _ g: CGGradient, from: CGPoint, to: CGPoint) {
        saveGState()
        addPath(path); setLineWidth(width); replacePathWithStrokedPath(); clip()
        linear(g, from: from, to: to)
        restoreGState()
    }

    /// Shadow cast inward from the edge of `path` (makes it look recessed).
    func innerShadow(_ path: CGPath, offset: CGSize, blur: CGFloat, color: CGColor) {
        clipped(to: path) {
            let outside = CGMutablePath()
            outside.addRect(CGRect(x: -600, y: -600, width: canvas + 1200, height: canvas + 1200))
            outside.addPath(path)
            setShadow(offset: offset, blur: blur, color: color)
            addPath(outside); setFillColor(black(1)); fillPath(using: .evenOdd)
        }
    }
}

/// Deterministic grey noise; a narrow `width` stretched across the canvas gives brushed streaks.
func noise(width: Int, height: Int, seed: UInt64) -> CGImage {
    var state = seed
    var bytes = [UInt8](repeating: 0, count: width * height)
    for i in bytes.indices {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        bytes[i] = UInt8(truncatingIfNeeded: state >> 56)
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

// MARK: - Render

func render(_ style: String) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // Drop shadow under the plate.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: black(0.45))
    ctx.fill(platePath, rgb(0x1E1D24))
    ctx.restoreGState()

    drawPlate(ctx, style)
    drawWell(ctx, style)
    for i in 0..<segments { drawSegment(ctx, i, lit: i < lit, style: style) }
    drawDisc(ctx, style)
    drawFinish(ctx, style)
    return ctx.makeImage()!
}

func drawPlate(_ ctx: CGContext, _ style: String) {
    let top = CGPoint(x: 512, y: 924), bottom = CGPoint(x: 512, y: 100)
    ctx.clipped(to: platePath) {
        switch style {
        case "aluminum":
            ctx.linear(gradient([(rgb(0xEEF0F3), 0), (rgb(0xC9CCD2), 0.55), (rgb(0xA7ABB3), 1)]), from: top, to: bottom)
            // Brushed grain: horizontal streaks plus a little fine noise.
            ctx.setAlpha(0.13); ctx.setBlendMode(.multiply)
            ctx.draw(noise(width: 6, height: 700, seed: 7), in: plateRect)
            ctx.setAlpha(0.06)
            ctx.draw(noise(width: 512, height: 512, seed: 11), in: plateRect)
            ctx.setAlpha(1); ctx.setBlendMode(.normal)
            // Violet light reflecting off the metal near the lit segments.
            ctx.radial(gradient([(rgb(0x785CFF, 0.22), 0), (rgb(0x785CFF, 0), 1)]), at: CGPoint(x: 620, y: 420), to: 480)
        case "titanium":
            ctx.linear(gradient([(rgb(0x50525C), 0), (rgb(0x2C2D34), 0.6), (rgb(0x1F2026), 1)]), from: top, to: bottom)
            // Spun-metal finish: anisotropic reflections plus fine concentric machining.
            ctx.setBlendMode(.overlay)
            ctx.conic([(white(0.0), 0), (white(0.55), 0.12), (white(0.0), 0.25), (white(0.35), 0.37),
                                            (white(0.0), 0.5), (white(0.55), 0.62), (white(0.0), 0.75), (white(0.35), 0.87), (white(0.0), 1)], at: center, angle: .pi / 5)
            ctx.setBlendMode(.normal)
            var seed: UInt64 = 3
            for r in stride(from: CGFloat(6), through: 600, by: 2.2) {
                seed = seed &* 6364136223846793005 &+ 1
                let a = 0.025 + CGFloat(seed >> 60) / 15 * 0.05
                ctx.addPath(circle(r)); ctx.setStrokeColor(seed >> 59 & 1 == 0 ? white(a) : black(a * 1.6))
                ctx.setLineWidth(1.1); ctx.strokePath()
            }
            ctx.radial(gradient([(rgb(0x785CFF, 0.28), 0), (rgb(0x785CFF, 0), 1)]), at: CGPoint(x: 600, y: 420), to: 480)
        case "glass":
            // Coloured light behind frosted glass.
            ctx.linear(gradient([(rgb(0x2A2170), 0), (rgb(0x120E30), 1)]), from: top, to: bottom)
            ctx.radial(gradient([(rgb(0x8B6CFF, 0.95), 0), (rgb(0x8B6CFF, 0), 1)]), at: CGPoint(x: 330, y: 760), to: 420)
            ctx.radial(gradient([(rgb(0x3D86FF, 0.7), 0), (rgb(0x3D86FF, 0), 1)]), at: CGPoint(x: 760, y: 260), to: 420)
            ctx.radial(gradient([(rgb(0xD45CFF, 0.5), 0), (rgb(0xD45CFF, 0), 1)]), at: CGPoint(x: 800, y: 800), to: 320)
            ctx.fill(platePath, white(0.07))
            ctx.setAlpha(0.05)
            ctx.draw(noise(width: 512, height: 512, seed: 5), in: plateRect)
            ctx.setAlpha(1)
        case "obsidian":
            ctx.linear(gradient([(rgb(0x1C1C23), 0), (rgb(0x0A0A0E), 1)]), from: top, to: bottom)
            ctx.radial(gradient([(rgb(0x785CFF, 0.38), 0), (rgb(0x785CFF, 0), 1)]), at: CGPoint(x: 600, y: 400), to: 520)
        default:  // flat
            ctx.linear(gradient([(rgb(0x302F38), 0), (rgb(0x1A1920), 1)]), from: top, to: bottom)
            ctx.radial(gradient([(rgb(0x785CFF, 0.42), 0), (rgb(0x785CFF, 0.12), 0.45), (rgb(0x785CFF, 0), 1)]),
                       at: CGPoint(x: 600, y: 400), to: 520)
        }
    }

    // Bevelled edge: lit from above.
    let edge = CGPath(roundedRect: plateRect.insetBy(dx: 2, dy: 2), cornerWidth: plateRadius - 2, cornerHeight: plateRadius - 2, transform: nil)
    let top2 = CGPoint(x: 512, y: 924), bottom2 = CGPoint(x: 512, y: 100)
    switch style {
    case "aluminum":
        ctx.stroke(edge, width: 4, gradient([(white(0.95), 0), (white(0.3), 0.5), (rgb(0x5E626C, 0.9), 1)]), from: top2, to: bottom2)
    case "titanium":
        ctx.stroke(edge, width: 4, gradient([(white(0.55), 0), (white(0.05), 0.5), (black(0.6), 1)]), from: top2, to: bottom2)
    case "glass":
        ctx.stroke(edge, width: 6, gradient([(white(0.9), 0), (white(0.15), 0.55), (white(0.35), 1)]),
                   from: CGPoint(x: 160, y: 900), to: CGPoint(x: 880, y: 120))
    case "obsidian":
        ctx.stroke(edge, width: 3, gradient([(white(0.4), 0), (white(0.02), 0.4), (white(0.08), 1)]), from: top2, to: bottom2)
    default:
        ctx.stroke(edge, width: 3, gradient([(white(0.16), 0), (white(0), 0.35)]), from: top2, to: bottom2)
    }
}

func drawWell(_ ctx: CGContext, _ style: String) {
    let well = circle(wellRadius)
    let top = CGPoint(x: 512, y: 512 + wellRadius + 24), bottom = CGPoint(x: 512, y: 512 - wellRadius - 24)

    // Bezel around the well.
    let bezel = CGMutablePath(); bezel.addPath(circle(wellRadius + 22)); bezel.addPath(circle(wellRadius))
    ctx.saveGState(); ctx.addPath(bezel); ctx.clip(using: .evenOdd)
    switch style {
    case "aluminum":  // chamfer sloping into the recess: shaded at the top, catching light at the bottom
        ctx.linear(gradient([(rgb(0x8A8E97), 0), (rgb(0xC4C7CD), 0.5), (rgb(0xFAFBFC), 1)]), from: top, to: bottom)
    case "titanium":  // polished ring
        ctx.conic([(rgb(0x2A2B31), 0), (rgb(0xC9CBD3), 0.12), (rgb(0x3A3B42), 0.3), (rgb(0x8E909A), 0.5),
                                        (rgb(0x26272D), 0.68), (rgb(0xDADCE3), 0.85), (rgb(0x2A2B31), 1)], at: center, angle: .pi / 4)
    case "glass":
        ctx.fill(bezel, white(0.10))
    default:
        break
    }
    ctx.restoreGState()

    ctx.clipped(to: well) {
        switch style {
        case "glass":
            ctx.fill(well, rgb(0x07061A, 0.55))
        case "aluminum":
            ctx.radial(gradient([(rgb(0x0C0C11), 0), (rgb(0x15151B), 0.7), (rgb(0x1E1E26), 1)]), at: center, to: wellRadius)
        default:
            ctx.radial(gradient([(rgb(0x0F0E14), 0), (rgb(0x16151C), 0.6), (rgb(0x1D1C24), 1)]), at: center, to: wellRadius)
        }
    }
    if style != "flat" {
        ctx.innerShadow(well, offset: CGSize(width: 0, height: -12), blur: 30, color: black(style == "glass" ? 0.6 : 0.9))
    }

    // Thin glowing rim.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: rgb(0x785CFF, 0.9))
    ctx.addPath(well); ctx.setLineWidth(style == "flat" ? 5 : 3.5)
    ctx.setStrokeColor(rgb(0x8C74FF, style == "glass" ? 0.8 : 0.55)); ctx.strokePath()
    ctx.restoreGState()
}

func drawSegment(_ ctx: CGContext, _ index: Int, lit: Bool, style: String) {
    let path = segmentPath(index)
    let box = path.boundingBox
    let gloss: CGFloat = ["flat": 0, "aluminum": 0.35, "titanium": 0.3, "glass": 0.55, "obsidian": 0.6][style] ?? 0

    if lit {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 46, color: rgb(0x785CFF, 0.95))
        ctx.fill(path, violet)
        ctx.restoreGState()
        ctx.clipped(to: path) {
            let stops: [(CGColor, CGFloat)] = style == "glass"
                ? [(rgb(0xF2EEFF), 0), (rgb(0xB7A4FF), 0.4), (rgb(0x7A58FF), 1)]
                : [(rgb(0xE4DCFF), 0), (rgb(0x9F86FF), 0.45), (rgb(0x6A47F5), 1)]
            ctx.radial(gradient(stops), at: center, from: innerRadius - 20, to: outerRadius + 20)
        }
    } else {
        switch style {
        case "glass": ctx.fill(path, white(0.09))
        case "obsidian": ctx.fill(path, rgb(0x16161B))
        case "aluminum": ctx.fill(path, rgb(0x26262E))
        case "titanium": ctx.fill(path, rgb(0x25262C))
        default: ctx.fill(path, rgb(0x2E2D35))
        }
        if style != "flat" { ctx.innerShadow(path, offset: CGSize(width: 0, height: -4), blur: 8, color: black(0.55)) }
    }

    // Specular highlight from a light above, and a fine rim on glassy styles.
    if gloss > 0 {
        let strength = lit ? gloss : gloss * 0.4
        ctx.clipped(to: path) {
            ctx.linear(gradient([(white(strength), 0), (white(strength * 0.25), 0.45), (white(0), 0.6)]),
                       from: CGPoint(x: box.midX, y: box.maxY), to: CGPoint(x: box.midX, y: box.minY))
        }
    }
    if style == "glass" || style == "obsidian" {
        ctx.stroke(path, width: 3, gradient([(white(lit ? 0.7 : 0.45), 0), (white(0.05), 0.6)]),
                   from: CGPoint(x: box.midX, y: box.maxY), to: CGPoint(x: box.midX, y: box.minY))
    }
}

func drawDisc(_ ctx: CGContext, _ style: String) {
    let disc = circle(discRadius)
    let top = CGPoint(x: 512, y: 512 + discRadius), bottom = CGPoint(x: 512, y: 512 - discRadius)
    switch style {
    case "aluminum":  // a small brushed cap
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: black(0.7))
        ctx.fill(disc, rgb(0xC9CCD2))
        ctx.restoreGState()
        ctx.clipped(to: disc) {
            ctx.linear(gradient([(rgb(0xF4F5F7), 0), (rgb(0xB0B4BC), 1)]), from: top, to: bottom)
            ctx.setAlpha(0.12); ctx.setBlendMode(.multiply)
            ctx.draw(noise(width: 6, height: 400, seed: 9), in: disc.boundingBox)
        }
        ctx.stroke(disc, width: 3, gradient([(white(0.95), 0), (black(0.3), 1)]), from: top, to: bottom)
    case "titanium":
        ctx.clipped(to: disc) {
            ctx.conic([(rgb(0x2E2F36), 0), (rgb(0x9C9EA8), 0.13), (rgb(0x33343B), 0.3), (rgb(0x6E707A), 0.5),
                                            (rgb(0x2A2B31), 0.7), (rgb(0xA8AAB3), 0.86), (rgb(0x2E2F36), 1)], at: center, angle: .pi / 4)
        }
        ctx.stroke(disc, width: 3, gradient([(white(0.6), 0), (black(0.5), 1)]), from: top, to: bottom)
    case "glass":
        ctx.fill(disc, white(0.08))
        ctx.clipped(to: disc) { ctx.linear(gradient([(white(0.35), 0), (white(0), 0.5)]), from: top, to: bottom) }
        ctx.stroke(disc, width: 3, gradient([(white(0.7), 0), (white(0.1), 1)]), from: top, to: bottom)
    case "obsidian":
        ctx.fill(disc, rgb(0x0B0B0F))
        ctx.clipped(to: disc) { ctx.linear(gradient([(white(0.22), 0), (white(0), 0.45)]), from: top, to: bottom) }
    default:
        ctx.clipped(to: disc) { ctx.linear(gradient([(rgb(0x1B1A21), 0), (rgb(0x111016), 1)]), from: top, to: bottom) }
    }
}

/// Last pass: big reflections that sit on top of everything.
func drawFinish(_ ctx: CGContext, _ style: String) {
    switch style {
    case "glass":
        ctx.clipped(to: platePath) {
            ctx.clipped(to: CGPath(ellipseIn: CGRect(x: -40, y: 560, width: 1104, height: 700), transform: nil)) {
                ctx.linear(gradient([(white(0.30), 0), (white(0.06), 0.6), (white(0), 1)]),
                           from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 560))
            }
        }
    case "obsidian":
        ctx.clipped(to: platePath) {
            ctx.clipped(to: CGPath(ellipseIn: CGRect(x: -380, y: 420, width: 1500, height: 900), transform: nil)) {
                ctx.linear(gradient([(white(0.20), 0), (white(0.04), 0.7), (white(0), 1)]),
                           from: CGPoint(x: 200, y: 924), to: CGPoint(x: 700, y: 420))
            }
        }
    default:
        break
    }
}

// MARK: - Output

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

func writeIcns(_ master: CGImage, to out: URL) throws {
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try png(ctx.makeImage()!).write(to: iconset.appendingPathComponent(name))
        }
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
    try task.run()
    task.waitUntilExit()
    try? FileManager.default.removeItem(at: iconset)
    guard task.terminationStatus == 0 else { throw NSError(domain: "iconutil", code: Int(task.terminationStatus)) }
}

/// Every style on a light and a dark desktop, labelled, for picking one.
func writeSheet(to out: URL) throws {
    let cell: CGFloat = 380, pad: CGFloat = 30, label: CGFloat = 50
    let width = CGFloat(styles.count) * (cell + pad) + pad
    let rowHeight = cell + label + pad
    let height = rowHeight * 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let images = styles.map(render)
    for (row, background) in [NSColor(white: 0.93, alpha: 1), NSColor(srgbRed: 0.13, green: 0.13, blue: 0.17, alpha: 1)].enumerated() {
        let y = height - CGFloat(row + 1) * rowHeight
        background.setFill()
        NSRect(x: 0, y: y, width: width, height: rowHeight).fill()
        for (i, image) in images.enumerated() {
            let x = pad + CGFloat(i) * (cell + pad)
            NSImage(cgImage: image, size: NSSize(width: cell, height: cell)).draw(in: NSRect(x: x, y: y + label, width: cell, height: cell))
            let text = NSAttributedString(string: styles[i].capitalized, attributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
                .foregroundColor: row == 0 ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.85, alpha: 1)])
            text.draw(at: NSPoint(x: x + (cell - text.size().width) / 2, y: y + 12))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: out)
}

let args = CommandLine.arguments
let style = args.count > 1 ? args[1] : "flat"
let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "AppIcon.icns")
if style == "sheet" {
    try writeSheet(to: out)
} else {
    guard styles.contains(style) else { fatalError("Unknown style \(style); expected one of \(styles)") }
    let master = render(style)
    if out.pathExtension == "png" {
        try png(master).write(to: out)
    } else {
        try writeIcns(master, to: out)
        try png(master).write(to: out.deletingPathExtension().appendingPathExtension("png"))
    }
}
print("Wrote \(out.path)")
