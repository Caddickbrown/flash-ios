/*
 * TelemetrySheet.swift — Engine telemetry surface
 *
 * Presents SystemMetrics (RSS, headroom, CPU, thermal) next to the engine's
 * own generation stats, plus the derived per-token expert I/O that explains
 * where the time actually goes.
 */

import SwiftUI

struct TelemetrySheet: View {
    let engine: FlashMoEEngine
    let samples: [Double]

    @Environment(\.dismiss) private var dismiss
    @State private var metrics = SystemMetrics()
    @State private var timer: Timer?
    @AppStorage("cacheIOSplit") private var cacheIOSplit: Int = 1

    var body: some View {
        ZStack {
            FM.ground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .center) {
                        Text("Engine")
                            .font(FM.titleM)
                            .foregroundStyle(FM.ink)
                        Spacer(minLength: 12)
                        thermalBadge
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(FM.secondary)
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.06), in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")
                    }

                    rateCard
                    statGrid
                    layerCard
                    ioCard
                    fanoutCard
                }
                .padding(FM.S.gutter)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
#if os(iOS)
        .presentationDetents([.large])
        .presentationBackground(FM.ground)
        .presentationDragIndicator(.visible)
#else
        .frame(minWidth: 420, minHeight: 560)
#endif
        .onAppear(perform: startSampling)
        .onDisappear(perform: stopSampling)
    }

    // MARK: Rate

    private var rateCard: some View {
        FMCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    FMReadout(
                        value: String(format: "%.1f", max(engine.tokensPerSecond, 0)),
                        unit: engine.tokensGenerated < 0 ? "prefill tok/s" : "tok/s",
                        size: 30
                    )
                    Spacer()
                    FMLabel("this run")
                }
                Sparkline(samples: samples)
                    .frame(height: 58)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        if samples.count < 2 {
                            Text("No samples yet")
                                .font(FM.sans(12))
                                .foregroundStyle(FM.tertiary)
                        }
                    }
            }
        }
    }

    // MARK: Stats

    private var statGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            statTile("resident", String(format: "%.1f", metrics.residentMemoryMB / 1024), "GB", FM.ink)
            statTile("headroom", String(format: "%.1f", metrics.availableMemoryMB / 1024), "GB",
                     metrics.availableMemoryMB < 600 ? FM.stall : FM.stream)
            statTile("cpu", String(format: "%.0f", metrics.cpuUsagePercent), "%", FM.ink)
            statTile("ttft", engine.timeToFirstToken > 0 ? String(format: "%.0f", engine.timeToFirstToken) : "—", "ms", FM.ink)
            statTile("tokens", "\(abs(engine.tokensGenerated))", engine.tokensGenerated < 0 ? "pre" : "out", FM.ink)
            statTile("gpu bufs", engine.modelInfo.map { String(format: "%.0f", Double($0.metalBufferBytes) / 1_048_576) } ?? "—", "MB", FM.ink)
        }
    }

    private func statTile(_ label: String, _ value: String, _ unit: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FMLabel(label)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(FM.mono(17, .semibold))
                    .monospacedDigit()
                    .kerning(-0.6)
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(FM.mono(9))
                    .foregroundStyle(FM.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(FM.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: Time in a layer

    private static let phaseColors: [Color] = [FM.route, FM.stream, FM.flash, FM.stall]

    private var layerCard: some View {
        FMCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Time in a layer")
                        .font(FM.sans(13.5, .semibold))
                        .foregroundStyle(FM.ink)
                    Spacer()
                    if let timing = engine.layerTiming, !timing.isEmpty {
                        Text(String(format: "%.2f ms avg", timing.total))
                            .font(FM.mono(11.5))
                            .monospacedDigit()
                            .foregroundStyle(FM.secondary)
                    }
                }

                if let timing = engine.layerTiming, !timing.isEmpty {
                    let shares = timing.shares

                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Self.phaseColors[index % Self.phaseColors.count])
                                    .frame(width: max(2, share.fraction * (geo.size.width - 6)))
                            }
                        }
                    }
                    .frame(height: 26)
                    .animation(.easeOut(duration: 0.35), value: timing)

                    VStack(spacing: 7) {
                        ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Self.phaseColors[index % Self.phaseColors.count])
                                    .frame(width: 8, height: 8)
                                Text(share.label)
                                    .font(FM.sans(12))
                                    .foregroundStyle(FM.secondary)
                                Spacer()
                                Text(String(format: "%.2f ms", share.value))
                                    .font(FM.mono(11))
                                    .monospacedDigit()
                                    .foregroundStyle(Color(hex: 0xC7CCD4))
                            }
                        }
                    }

                    Text("Averaged over \(timing.layersSampled) layer passes this run.")
                        .font(FM.sans(11))
                        .foregroundStyle(FM.faint)
                } else {
                    Text("Send a message — the breakdown fills in as layers run.")
                        .font(FM.sans(12.5))
                        .foregroundStyle(FM.tertiary)
                }
            }
        }
    }

    // MARK: Per-token I/O

    /// Bytes pulled off storage for one token: K experts per layer, every layer.
    private var bytesPerToken: Double {
        guard let info = engine.modelInfo else { return 0 }
        return Double(info.expertSizeEach) * Double(info.activeExpertsK) * Double(info.numLayers)
    }

    private var ioCard: some View {
        FMCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Expert I/O per token")
                        .font(FM.sans(13.5, .semibold))
                        .foregroundStyle(FM.ink)
                    Spacer()
                    Text(String(format: "%.2f GB", bytesPerToken / 1_073_741_824))
                        .font(FM.mono(11.5))
                        .monospacedDigit()
                        .foregroundStyle(FM.stream)
                }

                if let info = engine.modelInfo {
                    VStack(spacing: 7) {
                        ioRow("Per expert", String(format: "%.2f MB", info.expertSizeEachMB))
                        ioRow("Experts per layer", "K = \(info.activeExpertsK) of \(info.numExperts)")
                        ioRow("Layers", "\(info.numLayers)")
                        if engine.tokensPerSecond > 0 {
                            ioRow("Sustained read", String(format: "%.2f GB/s", bytesPerToken * engine.tokensPerSecond / 1_073_741_824))
                        }
                    }
                } else {
                    Text("No model loaded.")
                        .font(FM.sans(12.5))
                        .foregroundStyle(FM.tertiary)
                }
            }
        }
    }

    private func ioRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(FM.sans(12))
                .foregroundStyle(FM.secondary)
            Spacer()
            Text(value)
                .font(FM.mono(11))
                .monospacedDigit()
                .foregroundStyle(Color(hex: 0xC7CCD4))
        }
    }

    // MARK: Fanout

    private var fanoutCard: some View {
        FMCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Expert I/O fanout")
                        .font(FM.sans(13.5, .semibold))
                        .foregroundStyle(FM.ink)
                    Text("Splits each expert read into page-aligned chunks issued in parallel. Takes effect on the next model load.")
                        .font(FM.sans(11.5))
                        .lineSpacing(2)
                        .foregroundStyle(FM.tertiary)
                }

                HStack(spacing: 3) {
                    ForEach([1, 2, 4, 8], id: \.self) { n in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { cacheIOSplit = n }
                        } label: {
                            Text(n == 1 ? "Off" : "\(n)×")
                                .font(FM.mono(11.5))
                                .foregroundStyle(cacheIOSplit == n ? FM.onFlash : FM.secondary)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(cacheIOSplit == n ? FM.flash : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
    }

    // MARK: Thermal

    private var thermalBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(thermalColor)
                .frame(width: 6, height: 6)
            FMLabel(thermalLabel, color: thermalColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(thermalColor.opacity(0.12), in: Capsule())
    }

    private var thermalColor: Color {
        switch metrics.thermalState {
        case .nominal: FM.stream
        case .fair: FM.flash
        case .serious: FM.stall
        case .critical: FM.danger
        @unknown default: FM.tertiary
        }
    }

    private var thermalLabel: String {
        switch metrics.thermalState {
        case .nominal: "cool"
        case .fair: "warm"
        case .serious: "hot"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    // MARK: Sampling

    private func startSampling() {
        metrics.sample()
        // SystemMetrics is a Sendable reference type, so capture it directly
        // rather than touching the main-actor-isolated @State from the timer.
        engine.refreshTiming()
        let metrics = metrics
        let engine = engine
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            metrics.sample()
            Task { @MainActor in engine.refreshTiming() }
        }
    }

    private func stopSampling() {
        timer?.invalidate()
        timer = nil
    }
}
