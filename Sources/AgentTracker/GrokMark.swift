import SwiftUI

/// Ring split by a diagonal channel, with a needle through that channel.
/// Drawn here so the Grok tab isn't an SF Symbol sparkle.
struct GrokMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path(Self.cgPath(in: rect))
    }

    /// Template image for the menu bar, so it follows light and dark menu bars.
    static let menuBarImage: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(cgPath(in: rect))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func cgPath(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = side * 0.36
        let inner = side * 0.20
        let channel = side * 0.100
        let needle = side * 0.052
        let reach = side * 0.67
        let path = CGMutablePath()

        func polar(_ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
            let radians = degrees * .pi / 180
            return CGPoint(
                x: center.x + cos(radians) * radius,
                y: center.y - sin(radians) * radius
            )
        }

        func offset(_ radius: CGFloat) -> CGFloat {
            asin(min(channel / radius, 0.99)) * 180 / .pi
        }

        func bow(from start: CGPoint, to end: CGPoint) {
            let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let radial = CGPoint(x: mid.x - center.x, y: mid.y - center.y)
            let len = max(hypot(radial.x, radial.y), 0.001)
            let bulge = side * 0.018
            path.addQuadCurve(
                to: end,
                control: CGPoint(x: mid.x + radial.x / len * bulge, y: mid.y + radial.y / len * bulge)
            )
        }

        func addBand(axisA: CGFloat, axisB: CGFloat) {
            let outerStart = axisA + offset(outer)
            let outerEnd = axisB - offset(outer)
            let innerEnd = axisB - offset(inner)
            let innerStart = axisA + offset(inner)
            var delta = outerEnd - outerStart
            if delta <= 0 { delta += 360 }
            let steps = max(16, Int(delta / 3))
            path.move(to: polar(outer, outerStart))
            for i in 1...steps {
                path.addLine(to: polar(outer, outerStart + delta * CGFloat(i) / CGFloat(steps)))
            }
            bow(from: polar(outer, outerEnd), to: polar(inner, innerEnd))
            var back = innerStart - innerEnd
            if back <= 0 { back += 360 }
            for i in 1...steps {
                path.addLine(to: polar(inner, innerEnd - back * CGFloat(i) / CGFloat(steps)))
            }
            bow(from: polar(inner, innerStart), to: polar(outer, outerStart))
            path.closeSubpath()
        }

        // Slash axis is 45° / 225°: lower-left to upper-right.
        addBand(axisA: 45, axisB: 225)
        addBand(axisA: 225, axisB: 45 + 360)

        let dir = CGVector(dx: cos(.pi / 4), dy: -sin(.pi / 4))
        let perp = CGVector(dx: -dir.dy, dy: dir.dx)
        let steps = 24
        func sample(_ t: CGFloat, _ sign: CGFloat) -> CGPoint {
            let width = needle * pow(max(0, 1 - t * t), 0.42)
            return CGPoint(
                x: center.x + dir.dx * reach * t + perp.dx * width * sign,
                y: center.y + dir.dy * reach * t + perp.dy * width * sign
            )
        }
        path.move(to: sample(-1, 1))
        for i in 1...steps {
            path.addLine(to: sample(-1 + 2 * CGFloat(i) / CGFloat(steps), 1))
        }
        for i in stride(from: steps, through: 0, by: -1) {
            path.addLine(to: sample(-1 + 2 * CGFloat(i) / CGFloat(steps), -1))
        }
        path.closeSubpath()
        return path
    }
}

/// Claude and Codex stay SF Symbols. Grok uses `GrokMark`.
struct PlatformIcon: View {
    var tab: MenuTab
    var menuBar = false

    var body: some View {
        switch tab {
        case .grok:
            if menuBar {
                Image(nsImage: GrokMark.menuBarImage)
                    .accessibilityLabel("Grok")
            } else {
                GrokMark()
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Grok")
            }
        case .claude, .codex:
            if let name = tab.symbolName {
                if menuBar {
                    Image(systemName: name)
                } else {
                    Image(systemName: name)
                        .font(.system(size: 16, weight: .bold))
                }
            }
        }
    }
}
