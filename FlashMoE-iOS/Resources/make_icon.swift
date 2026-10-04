import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("ctx")
}
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r)/255, CGFloat(g)/255, CGFloat(b)/255, a])!
}

// --- Background: deep indigo -> near black, diagonal ---
ctx.saveGState()
let bg = CGGradient(colorsSpace: cs,
                    colors: [rgb(58, 36, 122), rgb(19, 14, 46), rgb(9, 8, 20)] as CFArray,
                    locations: [0.0, 0.55, 1.0])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
ctx.restoreGState()

// --- Expert grid (MoE): 5x5 rounded cells, faint ---
let n = 5
let margin: CGFloat = S * 0.145
let span = S - margin * 2
let gap = span * 0.085
let cell = (span - gap * CGFloat(n - 1)) / CGFloat(n)
for r in 0..<n {
    for c in 0..<n {
        let x = margin + CGFloat(c) * (cell + gap)
        let y = margin + CGFloat(r) * (cell + gap)
        // Cells nearer the diagonal bolt path read as the "hot" experts.
        let dc = abs(CGFloat(c) - CGFloat(n - 1 - r)) / CGFloat(n - 1)
        let alpha: CGFloat = 0.045 + (1 - dc) * 0.075
        let p = CGPath(roundedRect: CGRect(x: x, y: y, width: cell, height: cell),
                       cornerWidth: cell * 0.26, cornerHeight: cell * 0.26, transform: nil)
        ctx.addPath(p); ctx.setFillColor(rgb(255, 255, 255, alpha)); ctx.fillPath()
    }
}

// --- Lightning bolt, classic 24x24 path scaled up ---
// M11 21 V14 H7 L13 3 V10 H17 Z   (y-down in source coords)
let pts: [(CGFloat, CGFloat)] = [(11,21), (11,14), (7,14), (13,3), (13,10), (17,10)]
let scale = S * 0.735 / 24.0
let bw = 10 * scale, bh = 18 * scale                 // bolt spans x 7..17, y 3..21
let ox = (S - bw) / 2 - 7 * scale
let oy = (S - bh) / 2 - 3 * scale
let bolt = CGMutablePath()
for (i, p) in pts.enumerated() {
    // flip y: CG origin is bottom-left, source path is y-down
    let pt = CGPoint(x: ox + p.0 * scale, y: S - (oy + p.1 * scale))
    i == 0 ? bolt.move(to: pt) : bolt.addLine(to: pt)
}
bolt.closeSubpath()

// Glow
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: S * 0.055, color: rgb(255, 165, 30, 0.55))
ctx.addPath(bolt); ctx.setFillColor(rgb(255, 190, 60, 1)); ctx.fillPath()
ctx.restoreGState()

// Gradient fill
ctx.saveGState()
ctx.addPath(bolt); ctx.clip()
let boltGrad = CGGradient(colorsSpace: cs,
                          colors: [rgb(255, 225, 130), rgb(255, 193, 55), rgb(255, 130, 10)] as CFArray,
                          locations: [0.0, 0.5, 1.0])!
ctx.drawLinearGradient(boltGrad, start: CGPoint(x: S * 0.35, y: S * 0.88),
                       end: CGPoint(x: S * 0.65, y: S * 0.12), options: [])
ctx.restoreGState()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path)")
