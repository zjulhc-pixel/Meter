import AppKit

/// Cuts the logo glyph out of an app icon (a glyph on a flat background) and returns it as a
/// template mask, so it can be drawn in any single colour like a native menu bar symbol.
func monochromeLogo(from icon: NSImage, pixels n: Int = 128) -> NSImage? {
    guard let rep = bitmap(n), let px = rep.bitmapData else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
    NSGraphicsContext.restoreGraphicsState()

    func rgba(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
        let i = (y * n + x) * 4
        return (Double(px[i]), Double(px[i + 1]), Double(px[i + 2]), Double(px[i + 3]))
    }
    // Background = median of the colours just inside the squircle's four edges.
    let probes = [(n / 2, n * 15 / 100), (n * 15 / 100, n / 2), (n * 85 / 100, n / 2), (n / 2, n * 85 / 100)]
        .map { rgba($0.0, $0.1) }
        .sorted { $0.0 + $0.1 + $0.2 < $1.0 + $1.1 + $1.2 }
    let bg = probes[probes.count / 2]

    let lo = n * 16 / 100, hi = n - lo
    var mask = [Double](repeating: 0, count: n * n)
    var minX = n, minY = n, maxX = 0, maxY = 0
    for y in lo..<hi {
        for x in lo..<hi {
            let c = rgba(x, y)
            guard c.3 > 200 else { continue }
            let distance = sqrt(pow(c.0 - bg.0, 2) + pow(c.1 - bg.1, 2) + pow(c.2 - bg.2, 2))
            let alpha = min(max((distance - 50) / 80, 0), 1)
            mask[y * n + x] = alpha
            if alpha > 0.3 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
    }
    guard maxX > minX, maxY > minY else { return nil }

    // Crop to a square around the glyph so every logo fills its slot the same way.
    let side = max(maxX - minX, maxY - minY) + 4
    let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    guard let out = bitmap(side), let o = out.bitmapData else { return nil }
    for y in 0..<side {
        for x in 0..<side {
            let sx = cx - side / 2 + x, sy = cy - side / 2 + y
            let alpha = (sx >= 0 && sy >= 0 && sx < n && sy < n) ? mask[sy * n + sx] : 0
            let i = (y * side + x) * 4
            o[i] = 0; o[i + 1] = 0; o[i + 2] = 0; o[i + 3] = UInt8(alpha * 255)
        }
    }
    let image = NSImage(size: NSSize(width: side, height: side))
    image.addRepresentation(out)
    image.isTemplate = true
    return image
}

private func bitmap(_ side: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: side * 4, bitsPerPixel: 32)
}

/// Draws `mask`'s alpha filled with `color`.
func drawTinted(_ mask: NSImage, in rect: NSRect, color: NSColor) {
    let tinted = NSImage(size: rect.size, flipped: false) { bounds in
        mask.draw(in: bounds)
        color.set()
        bounds.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: rect)
}
