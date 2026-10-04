/*
 * LoadingView.swift — Model warm-up
 *
 * Driven by the engine's load-progress callback: the ring shows completed
 * phases, and the checklist marks each one off as flashmoe_load() reaches it.
 * Resident memory is sampled alongside so there is a live signal even while a
 * long phase (mapping weights) is in flight.
 */

import SwiftUI

struct LoadingView: View {
    let modelName: String
    let phase: LoadPhase?
    let onCancel: () -> Void

    @State private var metrics = SystemMetrics()
    @State private var timer: Timer?

    /// Phase names in the order the engine reports them, so the checklist can
    /// be drawn before the engine has reached a given step.
    private static let stages = [
        "Reading model config",
        "Sizing KV cache",
        "Building Metal pipelines",
        "Mapping dense weights",
        "Loading tokenizer",
        "Opening expert files"
    ]

    private var step: Int { phase?.step ?? 0 }
    private var fraction: Double { phase?.fraction ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0xC7CCD4))
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
                .accessibilityLabel("Cancel loading")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            Spacer(minLength: 12)

            ring

            Text("Warming the engine")
                .font(FM.sans(22, .semibold))
                .kerning(-0.4)
                .foregroundStyle(FM.ink)
                .padding(.top, 28)

            Text(modelName)
                .font(FM.sans(13.5))
                .foregroundStyle(FM.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 40)
                .padding(.top, 7)

            checklist
                .padding(.horizontal, 24)
                .padding(.top, 26)

            Spacer(minLength: 12)

            footnote
        }
        .onAppear {
            metrics.sample()
            let metrics = metrics
            timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
                metrics.sample()
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Ring

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.055), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(FM.flash, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)

            VStack(spacing: 3) {
                Text("\(Int(fraction * 100))")
                    .font(FM.mono(34, .semibold))
                    .monospacedDigit()
                    .kerning(-1.5)
                    .foregroundStyle(FM.ink)
                    .contentTransition(.numericText())
                FMLabel("per cent")
            }
        }
        .frame(width: 148, height: 148)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading, \(Int(fraction * 100)) per cent. \(phase?.stage ?? "Starting")")
    }

    // MARK: Checklist

    private var checklist: some View {
        VStack(spacing: 3) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { index, stage in
                let state = stageState(index)
                HStack(spacing: 11) {
                    marker(for: state)
                    Text(stage)
                        .font(FM.sans(13.5))
                        .foregroundStyle(state == .current ? FM.ink : (state == .done ? FM.secondary : FM.faint))
                    Spacer(minLength: 8)
                    if state == .current {
                        Text("\(min(step + 1, phase?.total ?? Self.stages.count)) / \(phase?.total ?? Self.stages.count)")
                            .font(FM.mono(10.5))
                            .monospacedDigit()
                            .foregroundStyle(FM.flash)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(state == .current ? FM.flash.opacity(0.07) : Color.clear)
                )
            }
        }
        .animation(.easeOut(duration: 0.25), value: step)
    }

    private enum StageState { case done, current, pending }

    /// The engine reports a phase as it *completes* it, so step N means stages
    /// 0..<N are done and stage N is the one now running.
    private func stageState(_ index: Int) -> StageState {
        if index < step { return .done }
        if index == step { return .current }
        return .pending
    }

    @ViewBuilder
    private func marker(for state: StageState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(FM.stream)
                .frame(width: 16, height: 16)
                .background(FM.stream.opacity(0.16), in: Circle())
                .overlay(Circle().strokeBorder(FM.stream.opacity(0.4), lineWidth: 1))
        case .current:
            FMPulse(color: FM.flash, size: 16)
        case .pending:
            Circle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                .frame(width: 16, height: 16)
        }
    }

    // MARK: Footnote

    private var footnote: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                FMPulse(color: FM.flash, size: 6)
                Text(String(format: "%.0f MB resident", metrics.residentMemoryMB))
                    .font(FM.mono(11.5))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: 0xC7CCD4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FM.card, in: Capsule())
            .overlay(Capsule().strokeBorder(FM.hairline, lineWidth: 1))

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(FM.stream)
                Text("Experts stay on disk — they are read per token, so this step never loads the whole model.")
                    .font(FM.sans(12))
                    .lineSpacing(3)
                    .foregroundStyle(Color(hex: 0x9FD8D2))
            }
            .padding(14)
            .background(FM.stream.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(FM.stream.opacity(0.18), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 24)
    }
}
