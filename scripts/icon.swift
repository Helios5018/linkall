import AppKit

/// Package the approved artwork and the same small-size silhouettes used by the apps.
@main struct IconExporter {
    static func bitmap(side: Int, points: CGFloat? = nil, draw: (CGContext, CGRect) -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        draw(context, CGRect(x: 0, y: 0, width: side, height: side))
        rep.size = NSSize(width: points ?? CGFloat(side), height: points ?? CGFloat(side))
        return rep
    }
    static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for brand in LinkBrand.allCases {
            let iconset = destination.appendingPathComponent(brand.rawValue + ".iconset")
            try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: iconset) }
            for size in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let rep = bitmap(side: size * scale) { brand.draw(in: $1, context: $0, tile: true) }
                    let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
                    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
                }
            }
            let command = Process(); command.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
            command.arguments = ["-c", "icns", iconset.path, "-o", destination.appendingPathComponent(brand.rawValue + ".icns").path]
            try command.run(); command.waitUntilExit()
            guard command.terminationStatus == 0 else { throw NSError(domain: "IconExporter", code: Int(command.terminationStatus)) }
            let preview = bitmap(side: 1024) { brand.draw(in: $1, context: $0, tile: true) }
            try preview.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(brand.rawValue + ".png"))
            // Larger bitmap reps also cover the system's input source switcher.
            let template = NSImage(size: NSSize(width: 18, height: 18))
            for side in [18, 36, 64, 128] {
                template.addRepresentation(bitmap(side: side, points: 18) { brand.draw(in: $1, context: $0, tile: false) })
            }
            try template.tiffRepresentation!.write(to: destination.appendingPathComponent(brand.rawValue + "Template.tiff"))
        }
        let board = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 520, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: board)
        let c = NSGraphicsContext.current!.cgContext
        NSColor(srgbRed: 0.97, green: 0.98, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1280, height: 520).fill()
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: NSColor(srgbRed: 0.15, green: 0.18, blue: 0.25, alpha: 1)])
        }
        text("LinkAll  /  B · AURORA", x: 52, y: 452, size: 28, bold: true)
        text("原版流光玻璃 · 彩色应用图标 · 单色菜单栏与输入源图标", x: 52, y: 418, size: 15)
        let captions = ["连接三个能力", "表达与输入", "记录与回看", "任务与行动 · 规划中"]
        for (index, brand) in LinkBrand.allCases.enumerated() {
            let x = CGFloat(index) * 310 + 52
            brand.draw(in: CGRect(x: x, y: 204, width: 172, height: 172), context: c, tile: true)
            text(brand.rawValue, x: x + 10, y: 164, size: 23, bold: true)
            text(captions[index], x: x + 10, y: 137, size: 14)
            brand.draw(in: CGRect(x: x + 12, y: 74, width: 18, height: 18), context: c, tile: false)
            brand.draw(in: CGRect(x: x + 48, y: 72, width: 24, height: 24), context: c, tile: false)
            c.setFillColor(NSColor(srgbRed: 0.15, green: 0.18, blue: 0.25, alpha: 1).cgColor)
            c.fill(CGRect(x: x + 96, y: 64, width: 52, height: 40))
            brand.draw(in: CGRect(x: x + 113, y: 75, width: 18, height: 18), context: c, tile: false, ink: .white)
        }
        NSGraphicsContext.restoreGraphicsState()
        try board.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("BrandPreview.png"))
    }
}
