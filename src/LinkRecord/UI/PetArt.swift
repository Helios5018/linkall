import SwiftUI
import AppKit

/// Resolution-independent artwork; the face reacts to the same actions as the desktop pet.
struct PetArt: View {
    var style: String
    var tint: String
    var accessory: String
    var action: String = ""
    var customPath: String = ""
    private var fur: Color {
        switch tint {
        case "rose": return Color(red: 1, green: 0.85, blue: 0.86)
        case "mint": return Color(red: 0.80, green: 0.92, blue: 0.86)
        case "lavender": return Color(red: 0.88, green: 0.85, blue: 0.97)
        default: return Color(red: 1, green: 0.94, blue: 0.82)
        }
    }
    var body: some View {
        Group {
            if style == "custom", let image = NSImage(contentsOfFile: customPath) {
                Image(nsImage: image).resizable().scaledToFit().padding(8)
            } else {
                Canvas { context, size in
                    let scale = min(size.width, size.height) / 200
                    context.translateBy(x: (size.width - 200 * scale) / 2, y: (size.height - 200 * scale) / 2)
                    context.scaleBy(x: scale, y: scale)
                    draw(in: &context)
                }
            }
        }
        .accessibilityLabel(style == "custom" ? "自定义宠物形象" : style == "bunny" ? "棉花兔" : "糯米猫")
    }
    private func draw(in context: inout GraphicsContext) {
        let ink = Color(red: 0.37, green: 0.27, blue: 0.24)
        let edge = Color(red: 0.66, green: 0.49, blue: 0.36)
        let pink = Color(red: 0.98, green: 0.66, blue: 0.66)
        let warm = Color(red: 0.96, green: 0.72, blue: 0.43)
        func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h))
        }
        func shape(_ path: Path, _ color: Color, outline: Bool = true) {
            context.fill(path, with: .color(color))
            if outline { context.stroke(path, with: .color(edge), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)) }
        }
        func line(_ path: Path, color: Color = Color(red: 0.37, green: 0.27, blue: 0.24), width: CGFloat = 2.5) {
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        shape(ellipse(41, 177, 121, 12), .black.opacity(0.08), outline: false)
        // A curled tail and a small body make the head feel soft and oversized.
        if style == "bunny" {
            shape(ellipse(150, 139, 26, 28), .white)
        } else {
            let tail = Path { p in
                p.move(to: CGPoint(x: 148, y: 164))
                p.addCurve(to: CGPoint(x: 175, y: 132), control1: CGPoint(x: 183, y: 172), control2: CGPoint(x: 192, y: 132))
                p.addCurve(to: CGPoint(x: 165, y: 144), control1: CGPoint(x: 163, y: 131), control2: CGPoint(x: 159, y: 138))
                p.addCurve(to: CGPoint(x: 148, y: 148), control1: CGPoint(x: 173, y: 152), control2: CGPoint(x: 158, y: 151))
                p.closeSubpath()
            }
            shape(tail, fur)
        }
        shape(ellipse(55, 111, 92, 71), fur)
        shape(ellipse(77, 130, 49, 45), .white.opacity(0.70), outline: false)
        shape(ellipse(54, 165, 37, 19), fur)
        shape(ellipse(112, 165, 37, 19), fur)
        // Ears are drawn behind the head, with a folded tip on the kitten.
        if style == "bunny" {
            shape(Path(roundedRect: CGRect(x: 53, y: 5, width: 30, height: 84), cornerRadius: 17), fur)
            shape(Path(roundedRect: CGRect(x: 117, y: 9, width: 30, height: 81), cornerRadius: 17), fur)
            shape(Path(roundedRect: CGRect(x: 62, y: 15, width: 12, height: 54), cornerRadius: 8), pink.opacity(0.65), outline: false)
            shape(Path(roundedRect: CGRect(x: 126, y: 19, width: 12, height: 51), cornerRadius: 8), pink.opacity(0.65), outline: false)
        } else {
            shape(Path { p in
                p.move(to: CGPoint(x: 40, y: 79)); p.addQuadCurve(to: CGPoint(x: 44, y: 28), control: CGPoint(x: 31, y: 16))
                p.addQuadCurve(to: CGPoint(x: 84, y: 57), control: CGPoint(x: 62, y: 27)); p.closeSubpath()
            }, fur)
            shape(Path { p in
                p.move(to: CGPoint(x: 117, y: 55)); p.addQuadCurve(to: CGPoint(x: 157, y: 28), control: CGPoint(x: 146, y: 19))
                p.addQuadCurve(to: CGPoint(x: 161, y: 80), control: CGPoint(x: 169, y: 43)); p.closeSubpath()
            }, fur)
            shape(Path { p in
                p.move(to: CGPoint(x: 44, y: 61)); p.addQuadCurve(to: CGPoint(x: 48, y: 38), control: CGPoint(x: 41, y: 33))
                p.addLine(to: CGPoint(x: 67, y: 57)); p.closeSubpath()
            }, pink.opacity(0.70), outline: false)
            shape(Path { p in
                p.move(to: CGPoint(x: 134, y: 56)); p.addLine(to: CGPoint(x: 154, y: 38))
                p.addQuadCurve(to: CGPoint(x: 159, y: 64), control: CGPoint(x: 160, y: 37)); p.closeSubpath()
            }, pink.opacity(0.70), outline: false)
        }
        let head = Path { p in
            p.move(to: CGPoint(x: 100, y: 48))
            p.addCurve(to: CGPoint(x: 176, y: 100), control1: CGPoint(x: 145, y: 46), control2: CGPoint(x: 171, y: 65))
            p.addCurve(to: CGPoint(x: 100, y: 143), control1: CGPoint(x: 185, y: 134), control2: CGPoint(x: 144, y: 147))
            p.addCurve(to: CGPoint(x: 24, y: 100), control1: CGPoint(x: 55, y: 147), control2: CGPoint(x: 15, y: 134))
            p.addCurve(to: CGPoint(x: 100, y: 48), control1: CGPoint(x: 29, y: 65), control2: CGPoint(x: 55, y: 46))
            p.closeSubpath()
        }
        context.fill(head, with: .linearGradient(Gradient(colors: [.white, fur]), startPoint: CGPoint(x: 100, y: 48), endPoint: CGPoint(x: 100, y: 140)))
        context.stroke(head, with: .color(edge), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
        if style != "bunny" {
            for x: CGFloat in [89, 100, 111] {
                line(Path { p in p.move(to: CGPoint(x: x, y: 54)); p.addQuadCurve(to: CGPoint(x: x - 2, y: x == 100 ? 74 : 68), control: CGPoint(x: x + 1, y: 65)) }, color: tint == "cream" ? warm : edge.opacity(0.35), width: 5)
            }
        }
        shape(ellipse(37, 108, 27, 13), pink.opacity(0.48), outline: false)
        shape(ellipse(136, 108, 27, 13), pink.opacity(0.48), outline: false)
        for x: CGFloat in [69, 131] {
            if action == "摸摸" {
                line(Path { p in p.move(to: CGPoint(x: x - 7, y: 102)); p.addQuadCurve(to: CGPoint(x: x + 7, y: 102), control: CGPoint(x: x, y: 91)) })
            } else {
                shape(ellipse(x - 6, 90, 13, 19), ink, outline: false)
                shape(ellipse(x - 3, 92, 4.5, 5.5), .white, outline: false)
                shape(ellipse(x + 2, 102, 2.5, 2.5), .white.opacity(0.65), outline: false)
            }
        }
        shape(ellipse(96, 108, 8, 5), pink, outline: false)
        if action == "喂食" {
            shape(ellipse(95, 116, 10, 10), ink, outline: false)
            shape(ellipse(97, 122, 6, 3), pink, outline: false)
        } else {
            line(Path { p in
                p.move(to: CGPoint(x: 88, y: 116)); p.addCurve(to: CGPoint(x: 100, y: 114), control1: CGPoint(x: 91, y: 123), control2: CGPoint(x: 99, y: 122))
                p.addCurve(to: CGPoint(x: 112, y: 116), control1: CGPoint(x: 101, y: 122), control2: CGPoint(x: 109, y: 123))
            }, width: 2)
        }
        // Tiny front paws sit on top of the bib.
        shape(ellipse(61, 142, 23, 25), fur)
        shape(ellipse(117, 142, 23, 25), fur)
        if accessory == "scarf" {
            let scarf = Color(red: 0.64, green: 0.75, blue: 0.59)
            shape(Path(roundedRect: CGRect(x: 79, y: 139, width: 48, height: 10), cornerRadius: 5), scarf, outline: false)
            shape(Path(roundedRect: CGRect(x: 111, y: 144, width: 12, height: 19), cornerRadius: 4), scarf, outline: false)
            line(Path { p in p.move(to: CGPoint(x: 114, y: 157)); p.addLine(to: CGPoint(x: 120, y: 157)) }, color: .white.opacity(0.6), width: 2)
        } else if accessory == "flower" {
            for i in 0..<5 {
                let a = Double(i) * .pi * 2 / 5
                shape(ellipse(151 + cos(a) * 8 - 6, 68 + sin(a) * 8 - 6, 12, 12), .white, outline: false)
            }
            shape(ellipse(147, 64, 8, 8), warm, outline: false)
        } else if accessory == "bow" {
            shape(Path { p in p.move(to: CGPoint(x: 49, y: 65)); p.addQuadCurve(to: CGPoint(x: 29, y: 56), control: CGPoint(x: 27, y: 43)); p.addQuadCurve(to: CGPoint(x: 49, y: 65), control: CGPoint(x: 24, y: 79)); p.addQuadCurve(to: CGPoint(x: 67, y: 56), control: CGPoint(x: 71, y: 43)); p.addQuadCurve(to: CGPoint(x: 49, y: 65), control: CGPoint(x: 75, y: 79)) }, pink, outline: false)
            shape(ellipse(45, 60, 9, 10), Color(red: 0.89, green: 0.48, blue: 0.50), outline: false)
        }
    }
}
