/*
 * Theme.swift — Flash-MoE design system
 *
 * Dark-only, engine-room look: near-black ground, amber for work in flight,
 * teal for I/O, monospaced digits for anything the engine produces.
 * Nothing here uses stock SwiftUI chrome — no List, no default tint.
 *
 * Canvas: https://claude.ai/artifact/Nv2xdsqRrcQLW5dZHWE9N4
 */

import SwiftUI

// MARK: - Tokens

enum FM {

    // MARK: Surfaces & ink

    static let ground = Color(hex: 0x0B0C0E)
    static let card = Color(hex: 0x131519)
    static let raised = Color(hex: 0x17191D)
    static let sunken = Color(hex: 0x101215)
    static let hairline = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.10)

    static let ink = Color(hex: 0xF2F3F5)
    static let body = Color(hex: 0xDDE0E5)
    static let secondary = Color(hex: 0x8E95A1)
    static let tertiary = Color(hex: 0x6C737F)
    static let faint = Color(hex: 0x565C66)

    // MARK: Signal

    /// Generation, the loaded model, the primary action.
    static let flash = Color(hex: 0xFFB224)
    /// I/O, downloads, healthy headroom.
    static let stream = Color(hex: 0x34D6C8)
    /// Tiered quantisation, the attention phase.
    static let route = Color(hex: 0xA98BFF)
    /// Thermal pressure, errors, destructive actions.
    static let stall = Color(hex: 0xFF7A5C)
    static let danger = Color(hex: 0xFF6B60)
    static let onFlash = Color(hex: 0x15130C)

    // MARK: Geometry

    enum R {
        static let chip: CGFloat = 8
        static let control: CGFloat = 13
        static let card: CGFloat = 20
        static let sheet: CGFloat = 26
    }

    enum S {
        static let gutter: CGFloat = 16
        static let cardPad: CGFloat = 15
    }

    // MARK: Type
    //
    // Space Grotesk for text, JetBrains Mono for everything the engine
    // produces. See Fonts.swift for registration and the weight mapping.

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        FMFonts.sans(size, weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        FMFonts.mono(size, weight)
    }

    /// Small tracked-out monospace label — the system's section heading.
    static let label = FMFonts.mono(9.5)

    static let titleL = Font.system(size: 27, weight: .bold)
    static let titleM = Font.system(size: 20, weight: .semibold)
    static let bodyText = Font.system(size: 15)
    static let caption = Font.system(size: 12)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Primitives

/// Tracked-out mono caption used for every section heading and unit label.
struct FMLabel: View {
    let text: String
    var color: Color = FM.tertiary

    init(_ text: String, color: Color = FM.tertiary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(FM.label)
            .tracking(0.85)
            .foregroundStyle(color)
    }
}

/// The house card: raised surface, hairline edge, generous radius.
struct FMCard<Content: View>: View {
    var fill: Color = FM.card
    var stroke: Color = FM.hairline
    var radius: CGFloat = FM.R.card
    var padding: CGFloat = FM.S.cardPad
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
    }
}

/// Mono metadata pill — quantisation, layer counts, sizes.
struct FMChip: View {
    let text: String
    var color: Color = FM.secondary
    var tint: Color = Color.white.opacity(0.055)

    var body: some View {
        Text(text.uppercased())
            .font(FM.mono(9))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint, in: RoundedRectangle(cornerRadius: FM.R.chip, style: .continuous))
    }

    static func quant(_ kind: QuantKind) -> FMChip {
        switch kind {
        case .tiered: FMChip(text: "tiered", color: FM.route, tint: FM.route.opacity(0.14))
        case .fourBit: FMChip(text: "4-bit", color: FM.stream, tint: FM.stream.opacity(0.14))
        case .twoBit: FMChip(text: "2-bit", color: FM.flash, tint: FM.flash.opacity(0.14))
        }
    }

    enum QuantKind { case tiered, fourBit, twoBit }
}

/// Filled amber action.
struct FMPrimaryButton: ButtonStyle {
    var expands = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FM.sans(13.5, .semibold))
            .foregroundStyle(FM.onFlash)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: 40)
            .background(FM.flash, in: RoundedRectangle(cornerRadius: FM.R.control, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Hairline-outlined secondary action.
struct FMGhostButton: ButtonStyle {
    var tint: Color = FM.body
    var expands = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(FM.sans(13.5, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: 40)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: FM.R.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FM.R.control, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 36pt square icon button with a 44pt hit area.
struct FMIconButton: View {
    let system: String
    let label: String
    var tint: Color = Color(hex: 0xC7CCD4)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(FM.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(FM.hairlineStrong, lineWidth: 1)
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A glowing status dot — the "engine is doing work" tell.
struct FMPulse: View {
    var color: Color = FM.flash
    var size: CGFloat = 6
    var animated = true
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(on ? 0.95 : 0.45), radius: on ? 6 : 3)
            .opacity(on ? 1 : 0.65)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

/// Flat progress track. Used for downloads and load progress.
struct FMMeter: View {
    var value: Double
    var tint: Color = FM.stream
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .animation(.easeOut(duration: 0.3), value: value)
            }
        }
        .frame(height: height)
    }
}

/// The expert-routing strip: one cell per expert slot, lit where the router fired.
struct ExpertStrip: View {
    var cells: Int = 48
    var lit: Set<Int>
    var tint: Color = FM.flash
    var height: CGFloat = 16

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<cells, id: \.self) { i in
                let on = lit.contains(i)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(on ? tint : Color.white.opacity(0.055))
                    .shadow(color: on ? tint.opacity(0.6) : .clear, radius: on ? 5 : 0)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.18), value: lit)
    }
}

/// Fixed-width trailing sparkline over a rolling sample buffer.
struct Sparkline: View {
    var samples: [Double]
    var tint: Color = FM.flash

    var body: some View {
        GeometryReader { geo in
            let points = normalized(in: geo.size)
            if points.count > 1 {
                Path { p in
                    p.move(to: points[0])
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        let hi = max(samples.max() ?? 1, 0.001)
        let lo = min(samples.min() ?? 0, hi - 0.001)
        let span = max(hi - lo, 0.001)
        let step = size.width / CGFloat(samples.count - 1)
        return samples.enumerated().map { i, v in
            CGPoint(
                x: CGFloat(i) * step,
                y: size.height - CGFloat((v - lo) / span) * size.height
            )
        }
    }
}

/// Big monospaced readout with its unit — the house way of showing a number.
struct FMReadout: View {
    let value: String
    let unit: String
    var size: CGFloat = 26
    var tint: Color = FM.flash

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(FM.mono(size, .semibold))
                .monospacedDigit()
                .kerning(-1)
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(unit)
                .font(FM.mono(10))
                .foregroundStyle(FM.secondary)
        }
    }
}

// MARK: - Screen chrome

/// Every screen sits on the ground colour with the status area left bare —
/// no fake bars, no stock navigation.
struct FMScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            FM.ground.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
    }
}
