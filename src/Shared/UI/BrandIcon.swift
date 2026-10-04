import AppKit

/// Approved B / AURORA artwork plus optical-size monochrome silhouettes.
public enum LinkBrand: String, CaseIterable, Sendable {
    case all = "LinkAll", input = "LinkInput", record = "LinkRecord", agent = "LinkAgent"

    // Trim the generated masters to their tile, then fit all four to one macOS icon grid.
    // Coordinates are in the 1254 × 1254 source bitmap, measured from its top-left.
    private var tileBounds: CGRect {
        switch self {
        case .all: return CGRect(x: 130, y: 152, width: 992, height: 964)
        case .input: return CGRect(x: 97, y: 128, width: 1059, height: 1017)
        case .record: return CGRect(x: 114, y: 138, width: 1025, height: 989)
        case .agent: return CGRect(x: 77, y: 105, width: 1100, height: 1040)
        }
    }
    private static let artwork: [LinkBrand: CGImage] = {
        #if SWIFT_PACKAGE
        let directory = Bundle.main.url(forResource: "BrandAssets", withExtension: nil)
            ?? Bundle.module.resourceURL!.appendingPathComponent("BrandAssets")
        #else
        // The standalone export tool receives the same master directory explicitly.
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        #endif
        return Dictionary(uniqueKeysWithValues: allCases.map { brand in
            let url = directory.appendingPathComponent(brand.rawValue + ".png")
            guard let source = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let tile = source.cropping(to: brand.tileBounds) else {
                preconditionFailure("Missing or invalid bundled brand artwork: \(brand.rawValue)")
            }
            return (brand, tile)
        })
    }()

    public func image(size: CGFloat = 18, tile: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            self.draw(in: rect, context: context, tile: tile)
            return true
        }
        image.isTemplate = !tile
        image.accessibilityDescription = rawValue
        return image
    }

    public func draw(in rect: CGRect, context c: CGContext, tile: Bool, ink: NSColor = .black) {
        c.saveGState(); defer { c.restoreGState() }
        c.translateBy(x: rect.minX, y: rect.minY)
        c.scaleBy(x: rect.width / 32, y: rect.height / 32)
        if tile {
            c.interpolationQuality = .high
            c.draw(Self.artwork[self]!, in: CGRect(x: 2, y: 2, width: 28, height: 28))
            return
        }
        // Silhouettes use top-left coordinates for easier comparison with the approved board.
        c.translateBy(x: 0, y: 32); c.scaleBy(x: 1, y: -1)
        c.setFillColor(ink.cgColor); c.setStrokeColor(ink.cgColor)
        c.setLineCap(.round); c.setLineJoin(.round)
        switch self {
        case .all:
            let p = CGMutablePath()
            p.move(to: .init(x: 16, y: 3))
            p.addCurve(to: .init(x: 28, y: 19), control1: .init(x: 21, y: 3), control2: .init(x: 25, y: 13))
            p.addCurve(to: .init(x: 24, y: 29), control1: .init(x: 32, y: 27), control2: .init(x: 29, y: 30))
            p.addCurve(to: .init(x: 6, y: 28), control1: .init(x: 18, y: 30), control2: .init(x: 10, y: 30))
            p.addCurve(to: .init(x: 4, y: 18), control1: .init(x: 1, y: 27), control2: .init(x: 1, y: 24))
            p.addCurve(to: .init(x: 16, y: 3), control1: .init(x: 9, y: 7), control2: .init(x: 11, y: 3))
            p.closeSubpath()
            p.move(to: .init(x: 15, y: 10))
            p.addCurve(to: .init(x: 11, y: 22), control1: .init(x: 12, y: 12), control2: .init(x: 9, y: 19))
            p.addCurve(to: .init(x: 23, y: 19), control1: .init(x: 13, y: 25), control2: .init(x: 20, y: 22))
            p.addCurve(to: .init(x: 15, y: 10), control1: .init(x: 22, y: 16), control2: .init(x: 18, y: 10))
            p.closeSubpath(); c.addPath(p); c.drawPath(using: .eoFill)
            c.setBlendMode(.clear); c.setLineWidth(0.9)
            c.move(to: .init(x: 16, y: 4)); c.addCurve(to: .init(x: 27, y: 19), control1: .init(x: 10, y: 9), control2: .init(x: 25, y: 11)); c.strokePath()
            c.move(to: .init(x: 4, y: 24)); c.addCurve(to: .init(x: 23, y: 20), control1: .init(x: 9, y: 31), control2: .init(x: 19, y: 26)); c.strokePath()
        case .input:
            let p = CGMutablePath()
            p.move(to: .init(x: 17, y: 4))
            p.addCurve(to: .init(x: 29, y: 15), control1: .init(x: 25, y: 3), control2: .init(x: 29, y: 8))
            p.addCurve(to: .init(x: 16, y: 26), control1: .init(x: 29, y: 23), control2: .init(x: 23, y: 25))
            p.addCurve(to: .init(x: 7, y: 30), control1: .init(x: 11, y: 26), control2: .init(x: 9, y: 31))
            p.addCurve(to: .init(x: 7, y: 23), control1: .init(x: 5, y: 30), control2: .init(x: 8, y: 26))
            p.addCurve(to: .init(x: 3, y: 15), control1: .init(x: 4, y: 21), control2: .init(x: 3, y: 19))
            p.addCurve(to: .init(x: 17, y: 4), control1: .init(x: 3, y: 8), control2: .init(x: 9, y: 4))
            p.closeSubpath()
            p.addRoundedRect(in: CGRect(x: 14.5, y: 10, width: 3, height: 11), cornerWidth: 1.5, cornerHeight: 1.5)
            c.addPath(p); c.drawPath(using: .eoFill)
        case .record:
            c.addPath(CGPath(roundedRect: CGRect(x: 2, y: 9, width: 3, height: 17), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); c.fillPath()
            c.addPath(CGPath(roundedRect: CGRect(x: 7, y: 6, width: 3, height: 23), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); c.fillPath()
            let p = CGMutablePath()
            p.move(to: .init(x: 16, y: 3)); p.addLine(to: .init(x: 27, y: 6))
            p.addQuadCurve(to: .init(x: 30, y: 10), control: .init(x: 30, y: 7))
            p.addLine(to: .init(x: 30, y: 24)); p.addQuadCurve(to: .init(x: 27, y: 27), control: .init(x: 30, y: 26))
            p.addLine(to: .init(x: 16, y: 30)); p.addQuadCurve(to: .init(x: 12, y: 27), control: .init(x: 12, y: 31))
            p.addLine(to: .init(x: 12, y: 6)); p.addQuadCurve(to: .init(x: 16, y: 3), control: .init(x: 12, y: 2)); p.closeSubpath()
            p.addRoundedRect(in: CGRect(x: 17, y: 11, width: 8, height: 12), cornerWidth: 2, cornerHeight: 2)
            c.addPath(p); c.drawPath(using: .eoFill)
        case .agent:
            c.move(to: .init(x: 28, y: 3))
            c.addCurve(to: .init(x: 23, y: 26), control1: .init(x: 30, y: 1), control2: .init(x: 26, y: 19))
            c.addCurve(to: .init(x: 17, y: 27), control1: .init(x: 22, y: 31), control2: .init(x: 19, y: 31))
            c.addCurve(to: .init(x: 5, y: 18), control1: .init(x: 14, y: 20), control2: .init(x: 12, y: 18))
            c.addCurve(to: .init(x: 4, y: 15), control1: .init(x: 1, y: 18), control2: .init(x: 1, y: 17))
            c.addLine(to: .init(x: 28, y: 3)); c.closePath(); c.fillPath()
            c.setBlendMode(.clear); c.setLineWidth(1.15)
            c.move(to: .init(x: 4, y: 17)); c.addCurve(to: .init(x: 22, y: 29), control1: .init(x: 18, y: 12), control2: .init(x: 25, y: 18)); c.strokePath()
        }
    }
}
