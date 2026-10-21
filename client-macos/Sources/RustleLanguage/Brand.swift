import AppKit
import SwiftUI

/// RustleLanguage's mark: the Google Translate layout (a front card with a folded corner over a
/// grey card with 文), with an "R" instead of the "G" and the front card in RustleApp's black
/// (#1A1A1A, the same tile color as RustleApp's logo) instead of blue.
/// Drawn on a 1931-unit grid, the size of the reference artwork.
struct BrandMark: View {
    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 1931
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            let r: CGFloat = 128

            // Back card. Its left edge runs parallel to the front card's slanted edge, hidden behind it.
            var back = Path()
            back.move(to: p(551, 387))
            back.addLine(to: p(1931 - r, 387))
            back.addQuadCurve(to: p(1931, 387 + r), control: p(1931, 387))
            back.addLine(to: p(1931, 1931 - r))
            back.addQuadCurve(to: p(1931 - r, 1931), control: p(1931, 1931))
            back.addLine(to: p(1050, 1931))
            back.closeSubpath()
            ctx.fill(back, with: .linearGradient(Gradient(colors: [Color(hex: 0xE4E4E2), Color(hex: 0xD6D6D4)]),
                                                 startPoint: p(1000, 387), endPoint: p(1931, 1931)))

            ctx.draw(Text("文").font(.system(size: 860 * k, weight: .medium)).foregroundColor(Color(hex: 0x6B7A82)),
                     at: p(1478, 1150))

            // The fold under the front card.
            var fold = Path()
            fold.move(to: p(932, 1566)); fold.addLine(to: p(1382, 1566)); fold.addLine(to: p(1050, 1931))
            fold.closeSubpath()
            ctx.fill(fold, with: .color(Color(hex: 0x4D4A42)))

            // Front card: rounded on the left, slanted on the right.
            var front = Path()
            front.move(to: p(r, 0))
            front.addLine(to: p(878, 0))
            front.addLine(to: p(1382, 1566))
            front.addLine(to: p(r, 1566))
            front.addQuadCurve(to: p(0, 1566 - r), control: p(0, 1566))
            front.addLine(to: p(0, r))
            front.addQuadCurve(to: p(r, 0), control: p(0, 0))
            front.closeSubpath()
            ctx.fill(front, with: .linearGradient(Gradient(colors: [Color(hex: 0x2A2A29), DS.vast950]),
                                                  startPoint: p(0, 0), endPoint: p(1382, 1566)))

            ctx.draw(Text("R").font(.system(size: 820 * k, weight: .bold, design: .rounded)).foregroundColor(Color(hex: 0xEEEEEE)),
                     at: p(540, 790))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Brand row in the sidebar (RustleApp's BrandRow with the new mark and an "English" chip).
struct BrandRow: View {
    var body: some View {
        HStack(spacing: 8) {
            BrandMark().frame(width: 25, height: 25)
            Text("Rustle").font(DS.ui(18, .bold)).tracking(-0.3)
            Text("English")
                .font(DS.ui(11, .semibold))
                .foregroundColor(DS.fathom950)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color(hex: 0xE2F5F2)))
        }
        .padding(.horizontal, 5)
    }
}

/// The app icon: the mark on a white macOS tile (824 pt on a 1024 canvas, ~185 pt radius).
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [.white, DS.sand200], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
            BrandMark().frame(width: 600, height: 600)
        }
        .frame(width: 1024, height: 1024)
    }

    /// `RustleLanguage --icon <dir.iconset>`: writes every size iconutil needs.
    @MainActor
    static func writeIconset(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let renderer = ImageRenderer(content: AppIconView())
                renderer.scale = CGFloat(size * scale) / 1024
                guard let cg = renderer.cgImage else { continue }
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent(name))
            }
        }
    }
}
