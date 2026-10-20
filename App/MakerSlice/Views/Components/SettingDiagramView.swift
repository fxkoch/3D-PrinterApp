import SliceKit
import SwiftUI

/// Two small drawings side by side: what the print looks like with less / more of a setting.
struct SettingDiagramView: View {
    let kind: SettingDiagram

    var body: some View {
        HStack(spacing: 10) {
            panel(0, kind.captions.0)
            panel(1, kind.captions.1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Beispiel: \(kind.captions.0) und \(kind.captions.1)")
    }

    private func panel(_ variant: Int, _ caption: String) -> some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                SettingDiagramPainter(ctx: ctx, size: size).draw(kind, variant: variant)
            }
            .aspectRatio(1.35, contentMode: .fit)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            Text(caption).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

/// Stylised drawings; `variant` 0 is the left picture, 1 the right one.
struct SettingDiagramPainter {
    var ctx: GraphicsContext
    var size: CGSize

    private let plastic = Color.orange
    private let ink = Color.primary.opacity(0.75)
    private let hint = Color.primary.opacity(0.3)
    private let bad = Color.red
    private let good = Color.green

    private var w: CGFloat { size.width }
    private var h: CGFloat { size.height }

    private func line(_ points: [CGPoint], _ color: Color, width: CGFloat = 2, dash: [CGFloat] = []) {
        var p = SwiftUI.Path()
        guard let first = points.first else { return }
        p.move(to: first)
        points.dropFirst().forEach { p.addLine(to: $0) }
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
    }

    private func fill(_ path: SwiftUI.Path, _ color: Color) { ctx.fill(path, with: .color(color)) }
    private func stroke(_ path: SwiftUI.Path, _ color: Color, width: CGFloat = 2, dash: [CGFloat] = []) {
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
    }
    private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
    private func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> CGRect {
        CGRect(x: x * w, y: y * h, width: rw * w, height: rh * h)
    }
    private func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> SwiftUI.Path {
        SwiftUI.Path(ellipseIn: CGRect(x: (cx - r) * h + (w - h) / 2 + 0, y: (cy - r) * h, width: 2 * r * h, height: 2 * r * h))
    }

    func draw(_ kind: SettingDiagram, variant v: Int) {
        switch kind {
        case .layerHeight: layerHeight(v)
        case .lineWidth: lineWidth(v)
        case .wallCount: wallCount(v)
        case .infillDensity: infill(v)
        case .ironing: ironing(v)
        case .seam: seam(v)
        case .scarfSeam: scarf(v)
        case .bridge: bridge(v)
        case .overhang: overhang(v)
        case .elephantFoot: elephant(v)
        case .arcFitting: arc(v)
        case .supportGap: supportGap(v)
        case .brim: brim(v)
        case .fuzzySkin: fuzzy(v)
        case .crossingWalls: crossing(v)
        case .holeSize: hole(v)
        case .topShell: topShell(v)
        case .flow: flow(v)
        case .stringing: stringing(v)
        case .wallOrder: wallOrder(v)
        case .polyhole: polyhole(v)
        case .thinWall: thinWall(v)
        case .primeTower: primeTower(v)
        }
    }

    // MARK: - Pictures

    private func layerHeight(_ v: Int) {
        let steps = v == 0 ? 9 : 4
        var p = SwiftUI.Path()
        p.move(to: pt(0.08, 0.9))
        for i in 0..<steps {
            let x0 = 0.08 + 0.84 * CGFloat(i) / CGFloat(steps), x1 = 0.08 + 0.84 * CGFloat(i + 1) / CGFloat(steps)
            let y = 0.9 - 0.7 * CGFloat(i + 1) / CGFloat(steps)
            p.addLine(to: pt(x0, y)); p.addLine(to: pt(x1, y))
        }
        p.addLine(to: pt(0.92, 0.9)); p.closeSubpath()
        fill(p, plastic.opacity(0.8))
        line([pt(0.08, 0.9), pt(0.92, 0.2)], ink, width: 1.5, dash: [4, 3])
    }

    private func lineWidth(_ v: Int) {
        let n = v == 0 ? 7 : 4
        let lw = 0.84 / CGFloat(n)
        for r in 0..<2 {
            for i in 0..<n {
                let rr = CGRect(x: (0.08 + lw * CGFloat(i)) * w, y: (0.3 + 0.28 * CGFloat(r)) * h, width: lw * w * 0.94, height: 0.24 * h)
                fill(SwiftUI.Path(roundedRect: rr, cornerRadius: min(rr.height, rr.width) / 2), plastic.opacity(0.85))
            }
        }
    }

    private func wallCount(_ v: Int) {
        let walls = v == 0 ? 2 : 4
        let outer = rect(0.2, 0.1, 0.6, 0.8)
        fill(SwiftUI.Path(outer), hint.opacity(0.4))
        for i in 0..<walls {
            let inset = CGFloat(i) * 0.04
            stroke(SwiftUI.Path(outer.insetBy(dx: (0.02 + inset) * w, dy: (0.02 + inset) * w)), plastic, width: 3)
        }
        line([pt(0.4, 0.45), pt(0.6, 0.55), pt(0.4, 0.65), pt(0.6, 0.75)], hint, width: 1)
    }

    private func infill(_ v: Int) {
        let box = rect(0.22, 0.1, 0.56, 0.8)
        stroke(SwiftUI.Path(box), plastic, width: 3)
        let step = v == 0 ? 0.2 : 0.07
        var x = 0.22 + step
        while x < 0.78 { line([pt(x, 0.1), pt(x, 0.9)], plastic.opacity(0.7), width: 1.5); x += step }
        var y = 0.1 + step * 1.4
        while y < 0.9 { line([pt(0.22, y), pt(0.78, y)], plastic.opacity(0.7), width: 1.5); y += step * 1.4 }
    }

    private func ironing(_ v: Int) {
        fill(SwiftUI.Path(rect(0.1, 0.6, 0.8, 0.3)), plastic.opacity(0.5))
        var top = SwiftUI.Path()
        top.move(to: pt(0.1, 0.6))
        let n = 10
        for i in 0..<n {
            let x0 = 0.1 + 0.8 * CGFloat(i) / CGFloat(n), x1 = 0.1 + 0.8 * CGFloat(i + 1) / CGFloat(n)
            if v == 0 { top.addQuadCurve(to: pt(x1, 0.6), control: pt((x0 + x1) / 2, 0.44)) } else { top.addLine(to: pt(x1, 0.58)) }
        }
        stroke(top, plastic, width: 3)
        if v == 1 {
            line([pt(0.7, 0.18), pt(0.7, 0.4)], ink, width: 2)
            line([pt(0.65, 0.18), pt(0.75, 0.18)], ink, width: 4)
        }
    }

    private func seam(_ v: Int) {
        let c = circle(0.5, 0.5, 0.36)
        fill(c, plastic.opacity(0.5)); stroke(c, plastic, width: 3)
        if v == 0 {
            fill(SwiftUI.Path(ellipseIn: CGRect(x: w * 0.5 - 5, y: h * 0.86 - 5, width: 10, height: 10)), bad)
        } else {
            line([pt(0.5, 0.1), pt(0.5, 0.16)], good, width: 5)
            ctx.draw(Text("hinten").font(.caption2), at: pt(0.5, 0.04), anchor: .center)
        }
    }

    private func scarf(_ v: Int) {
        if v == 0 {
            line([pt(0.1, 0.55), pt(0.5, 0.55)], plastic, width: 8)
            line([pt(0.5, 0.45), pt(0.9, 0.45)], plastic, width: 8)
            fill(SwiftUI.Path(ellipseIn: rect(0.46, 0.38, 0.1, 0.25)), bad.opacity(0.6))
        } else {
            let a = pt(0.1, 0.5), b = pt(0.9, 0.5)
            line([a, pt(0.6, 0.5)], plastic.opacity(0.9), width: 8)
            line([pt(0.35, 0.5), b], plastic.opacity(0.9), width: 8)
            line([pt(0.35, 0.3), pt(0.6, 0.3)], good, width: 3)
            ctx.draw(Text("sanfter Übergang").font(.caption2), at: pt(0.5, 0.2), anchor: .center)
        }
    }

    private func bridge(_ v: Int) {
        fill(SwiftUI.Path(rect(0.08, 0.45, 0.18, 0.45)), ink.opacity(0.5))
        fill(SwiftUI.Path(rect(0.74, 0.45, 0.18, 0.45)), ink.opacity(0.5))
        var p = SwiftUI.Path()
        p.move(to: pt(0.26, 0.45))
        if v == 0 { p.addQuadCurve(to: pt(0.74, 0.45), control: pt(0.5, 0.95)) } else { p.addLine(to: pt(0.74, 0.45)) }
        stroke(p, plastic, width: 5)
    }

    private func overhang(_ v: Int) {
        fill(SwiftUI.Path(rect(0.15, 0.55, 0.3, 0.35)), ink.opacity(0.5))
        var p = SwiftUI.Path()
        p.move(to: pt(0.45, 0.55))
        for i in 0..<5 {
            let x = 0.45 + 0.45 * CGFloat(i + 1) / 5
            if v == 0 { p.addQuadCurve(to: pt(x, 0.5 + (i % 2 == 0 ? 0.12 : -0.02)), control: pt(x - 0.04, 0.7)) }
            else { p.addLine(to: pt(x, 0.55)) }
        }
        stroke(p, plastic, width: 5)
    }

    private func elephant(_ v: Int) {
        var p = SwiftUI.Path()
        p.move(to: pt(0.2, 0.9))
        if v == 0 { p.addLine(to: pt(0.14, 0.9)); p.addLine(to: pt(0.14, 0.78)); p.addQuadCurve(to: pt(0.2, 0.7), control: pt(0.14, 0.7)) }
        else { p.addLine(to: pt(0.2, 0.9)) }
        p.addLine(to: pt(0.2, 0.15)); p.addLine(to: pt(0.8, 0.15)); p.addLine(to: pt(0.8, 0.7))
        if v == 0 { p.addQuadCurve(to: pt(0.86, 0.78), control: pt(0.86, 0.7)); p.addLine(to: pt(0.86, 0.9)) } else { p.addLine(to: pt(0.8, 0.9)) }
        p.closeSubpath()
        fill(p, plastic.opacity(0.6)); stroke(p, plastic, width: 2.5)
        line([pt(0.2, 0.2), pt(0.2, 0.9)], ink, width: 1, dash: [3, 3])
    }

    private func arc(_ v: Int) {
        let center = CGPoint(x: w / 2, y: h / 2), r = h * 0.38
        if v == 0 {
            let n = 8
            var p = SwiftUI.Path()
            for i in 0...n {
                let a = 2 * .pi * Double(i) / Double(n)
                let pt = CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a)))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            stroke(p, plastic, width: 3)
        } else {
            stroke(circle(0.5, 0.5, 0.38), plastic, width: 3)
        }
    }

    private func supportGap(_ v: Int) {
        let gap: CGFloat = v == 0 ? 0.04 : 0.14
        fill(SwiftUI.Path(rect(0.15, 0.2, 0.7, 0.12)), plastic)
        for x in [0.2, 0.4, 0.6, 0.8] as [CGFloat] {
            line([pt(x - 0.01, 0.32 + gap), pt(x - 0.01, 0.9)], ink.opacity(0.7), width: 3)
        }
        fill(SwiftUI.Path(rect(0.15, 0.32 + gap, 0.7, 0.04)), ink.opacity(0.7))
        line([pt(0.9, 0.32), pt(0.9, 0.32 + gap)], bad, width: 2)
    }

    private func brim(_ v: Int) {
        if v == 1 {
            for i in 1...3 {
                let d = CGFloat(i) * 0.03
                stroke(SwiftUI.Path(rect(0.28 - d, 0.2 - d * 1.35, 0.44 + 2 * d, 0.6 + 2.7 * d)), plastic.opacity(0.7), width: 2)
            }
        }
        fill(SwiftUI.Path(rect(0.28, 0.2, 0.44, 0.6)), ink.opacity(0.5))
    }

    private func fuzzy(_ v: Int) {
        if v == 0 { stroke(circle(0.5, 0.5, 0.36), plastic, width: 3); return }
        let center = CGPoint(x: w / 2, y: h / 2), r = h * 0.36
        var p = SwiftUI.Path()
        let n = 60
        for i in 0...n {
            let a = 2 * .pi * Double(i) / Double(n)
            let rr = r + CGFloat((i * 37 % 7)) - 3
            let pt = CGPoint(x: center.x + rr * CGFloat(cos(a)), y: center.y + rr * CGFloat(sin(a)))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        stroke(p, plastic, width: 2.5)
    }

    private func crossing(_ v: Int) {
        stroke(SwiftUI.Path(rect(0.3, 0.15, 0.4, 0.7)), plastic, width: 3)
        stroke(SwiftUI.Path(rect(0.22, 0.1, 0.56, 0.8)), hint, width: 1, dash: [3, 3])
        if v == 0 {
            line([pt(0.1, 0.5), pt(0.9, 0.5)], bad, width: 2, dash: [4, 3])
        } else {
            line([pt(0.1, 0.5), pt(0.1, 0.95), pt(0.9, 0.95), pt(0.9, 0.5)], good, width: 2, dash: [4, 3])
        }
    }

    private func hole(_ v: Int) {
        fill(SwiftUI.Path(rect(0.15, 0.1, 0.7, 0.8)), plastic.opacity(0.5))
        let target = circle(0.5, 0.5, 0.26)
        stroke(target, ink, width: 1.5, dash: [3, 3])
        fill(circle(0.5, 0.5, v == 0 ? 0.19 : 0.26), Color(.secondarySystemBackground))
    }

    private func topShell(_ v: Int) {
        fill(SwiftUI.Path(rect(0.1, 0.55, 0.8, 0.35)), plastic.opacity(0.3))
        for x in stride(from: 0.14, through: 0.86, by: 0.12) { line([pt(x, 0.55), pt(x, 0.9)], plastic.opacity(0.6), width: 1.5) }
        let layers = v == 0 ? 1 : 4
        for i in 0..<layers { fill(SwiftUI.Path(rect(0.1, 0.55 - 0.08 * CGFloat(i + 1), 0.8, 0.07)), plastic.opacity(0.9)) }
        if v == 0 {
            for x in stride(from: 0.16, through: 0.84, by: 0.12) { line([pt(x, 0.48), pt(x, 0.55)], bad, width: 3) }
        }
    }

    private func flow(_ v: Int) {
        for i in 0..<5 {
            let x = 0.1 + 0.18 * CGFloat(i)
            let width: CGFloat = v == 0 ? 0.1 : 0.22
            let rr = rect(x, 0.3, width, 0.4)
            fill(SwiftUI.Path(roundedRect: rr, cornerRadius: 6), plastic.opacity(v == 0 ? 0.8 : 0.9))
        }
        if v == 1 { line([pt(0.1, 0.78), pt(0.9, 0.78)], bad, width: 2, dash: [3, 3]) }
    }

    private func stringing(_ v: Int) {
        fill(SwiftUI.Path(rect(0.15, 0.4, 0.12, 0.5)), plastic)
        fill(SwiftUI.Path(rect(0.73, 0.4, 0.12, 0.5)), plastic)
        if v == 0 {
            for y in [0.45, 0.55, 0.65] as [CGFloat] { line([pt(0.27, y), pt(0.5, y + 0.05), pt(0.73, y)], plastic.opacity(0.7), width: 1) }
        }
    }

    private func wallOrder(_ v: Int) {
        for i in 0..<3 {
            let d = CGFloat(i) * 0.09
            stroke(SwiftUI.Path(rect(0.2 + d, 0.12 + d * 1.3, 0.6 - 2 * d, 0.76 - 2.6 * d)), plastic, width: 3)
            let n = v == 0 ? 3 - i : i + 1
            ctx.draw(Text("\(n)").font(.caption2.bold()), at: pt(0.5, 0.12 + d * 1.3 + 0.07), anchor: .center)
        }
    }

    private func polyhole(_ v: Int) {
        fill(SwiftUI.Path(rect(0.15, 0.1, 0.7, 0.8)), plastic.opacity(0.5))
        let center = CGPoint(x: w / 2, y: h / 2), r = h * 0.26
        stroke(circle(0.5, 0.5, 0.26), ink, width: 1.5, dash: [3, 3])
        var p = SwiftUI.Path()
        let n = v == 0 ? 40 : 6
        let rr = v == 0 ? r * 0.8 : r
        for i in 0...n {
            let a = 2 * .pi * Double(i) / Double(n)
            let pt = CGPoint(x: center.x + rr * CGFloat(cos(a)), y: center.y + rr * CGFloat(sin(a)))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        fill(p, Color(.secondarySystemBackground))
    }

    private func thinWall(_ v: Int) {
        if v == 0 {
            line([pt(0.15, 0.4), pt(0.85, 0.4)], plastic, width: 6)
            line([pt(0.15, 0.6), pt(0.85, 0.6)], plastic, width: 6)
            line([pt(0.88, 0.4), pt(0.88, 0.6)], bad, width: 1.5)
        } else {
            line([pt(0.15, 0.5), pt(0.85, 0.5)], plastic, width: 9)
        }
    }

    private func primeTower(_ v: Int) {
        fill(SwiftUI.Path(rect(0.15, 0.3, 0.3, 0.45)), plastic.opacity(0.7))
        if v == 1 {
            fill(SwiftUI.Path(rect(0.62, 0.3, 0.2, 0.45)), ink.opacity(0.5))
            for i in 0..<5 { line([pt(0.62, 0.35 + 0.08 * CGFloat(i)), pt(0.82, 0.35 + 0.08 * CGFloat(i))], .primary.opacity(0.4), width: 1) }
        }
    }
}

/// All example pictures at once (UI tests look at them with `-uiTestDiagrams`).
struct SettingDiagramGallery: View {
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible())], spacing: 14) {
                ForEach(SettingDiagram.allCases, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.rawValue).font(.caption.bold())
                        SettingDiagramView(kind: kind)
                    }
                }
            }
            .padding()
        }
        .accessibilityIdentifier("diagramGallery")
    }
}
