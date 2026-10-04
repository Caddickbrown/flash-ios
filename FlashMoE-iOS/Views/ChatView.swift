/*
 * ChatView.swift — Chat surface for Flash-MoE inference
 *
 * Custom chrome throughout: an engine rail above the transcript showing tok/s,
 * time-to-first-token and live expert routing; user turns as amber-tinted
 * bubbles; assistant turns as plain text under a mono byline.
 */

import SwiftUI

// MARK: - Chat Message Model

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
    let timestamp: Date

    enum Role {
        case user
        case assistant
    }
}

// MARK: - Chat View

struct ChatView: View {
    @Environment(FlashMoEEngine.self) private var engine
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isGenerating = false
    @AppStorage("chatTemplateEnabled") private var chatTemplateEnabled: Bool = true
    @State private var showModelInfo = false
    @State private var showTelemetry = false
    @State private var rateSamples: [Double] = []
    @State private var litExperts: Set<Int> = []
    @FocusState private var inputFocused: Bool

    private var folderName: String {
        guard let name = engine.modelInfo?.name else { return "Flash-MoE" }
        return (name as NSString).lastPathComponent
    }

    var body: some View {
        FMScreen {
            VStack(spacing: 0) {
                header
                engineRail
                transcript
                composer
            }
        }
        .sheet(isPresented: $showModelInfo) { ModelInfoSheet(info: engine.modelInfo) }
        .sheet(isPresented: $showTelemetry) {
            TelemetrySheet(engine: engine, samples: rateSamples)
        }
        .onChange(of: engine.tokensPerSecond) { _, rate in
            guard rate > 0 else { return }
            rateSamples.append(rate)
            if rateSamples.count > 40 { rateSamples.removeFirst(rateSamples.count - 40) }
        }
        .onChange(of: engine.tokensGenerated) { _, _ in
            guard isGenerating else { return }
            reroll()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            FMIconButton(system: "chevron.left", label: "Back to models") {
                messages.removeAll()
                engine.reset()
                engine.unloadModel()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(folderName)
                    .font(FM.sans(15, .semibold))
                    .foregroundStyle(FM.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    FMPulse(color: isGenerating ? FM.flash : FM.stream, animated: isGenerating)
                    FMLabel(subtitle, color: FM.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FMIconButton(system: "cpu", label: "Model details") { showModelInfo = true }
            FMIconButton(system: "gauge.with.dots.needle.50percent", label: "Engine telemetry") {
                showTelemetry = true
            }
            FMIconButton(system: "plus", label: "New chat") {
                messages.removeAll()
                engine.reset()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var subtitle: String {
        guard let info = engine.modelInfo else { return "loading" }
        return "\(info.quantLabel) · \(info.numExperts) × K=\(info.activeExpertsK)"
    }

    // MARK: Engine rail

    private var engineRail: some View {
        FMCard(fill: FM.card, radius: 18, padding: 13) {
            VStack(spacing: 11) {
                HStack(alignment: .bottom, spacing: 10) {
                    FMReadout(
                        value: String(format: "%.1f", max(engine.tokensPerSecond, 0)),
                        unit: engine.tokensGenerated < 0 ? "prefill" : "tok/s"
                    )

                    Sparkline(samples: rateSamples)
                        .frame(height: 24)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .trailing, spacing: 2) {
                        FMLabel("ttft", color: FM.tertiary)
                        Text(engine.timeToFirstToken > 0
                             ? String(format: "%.0f ms", engine.timeToFirstToken)
                             : "—")
                            .font(FM.mono(12))
                            .monospacedDigit()
                            .foregroundStyle(Color(hex: 0xC7CCD4))
                    }
                }

                ExpertStrip(lit: litExperts, tint: isGenerating ? FM.flash : FM.tertiary.opacity(0.4))

                HStack {
                    FMLabel("experts routed", color: FM.tertiary)
                    Spacer()
                    if let info = engine.modelInfo {
                        FMLabel("\(info.activeExpertsK) / \(info.numExperts) active", color: FM.stream)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    /// Re-light the routing strip. The engine does not publish per-token expert
    /// ids, so this reflects the K-of-N shape of the routing rather than the
    /// exact indices.
    private func reroll() {
        let k = engine.modelInfo?.activeExpertsK ?? 8
        var next = Set<Int>()
        while next.count < min(k, 48) { next.insert(Int.random(in: 0..<48)) }
        litExperts = next
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if messages.isEmpty { emptyState }
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, FM.S.gutter)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { inputFocused = false }
            .onChange(of: messages.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: messages.last?.text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 22))
                .foregroundStyle(FM.flash)
            Text("Ready")
                .font(FM.titleM)
                .foregroundStyle(FM.ink)
            Text("Experts stay on disk. Only the ones a token routes to are read, so resident memory stays flat however large the model is.")
                .font(FM.sans(13.5))
                .lineSpacing(3)
                .foregroundStyle(FM.secondary)
        }
        .padding(.top, 40)
        .padding(.trailing, 40)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                TextField("", text: $inputText, prompt: Text("Message").foregroundStyle(FM.tertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(FM.sans(15.5))
                    .foregroundStyle(FM.ink)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .disabled(isGenerating)
                    .padding(.leading, 16)
                    .padding(.vertical, 11)

                sendButton
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
            }
            .background(FM.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(inputFocused ? FM.flash.opacity(0.35) : FM.hairlineStrong, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.2), value: inputFocused)

            FMLabel(footerStats, color: FM.faint)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var footerStats: String {
        let tokens = max(engine.tokensGenerated, 0)
        var parts = ["\(tokens) tokens"]
        if let info = engine.modelInfo {
            parts.append(String(format: "%.1f gb on disk", info.totalSizeGB))
        }
        return parts.joined(separator: " · ")
    }

    private var sendButton: some View {
        Button {
            if isGenerating { engine.cancel() } else { sendMessage() }
        } label: {
            ZStack {
                Circle().fill(FM.flash.opacity(isGenerating || !inputText.isEmpty ? 0.16 : 0.07))
                if isGenerating {
                    Circle()
                        .trim(from: 0, to: 0.6)
                        .stroke(FM.flash, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(1.2)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(FM.flash)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(inputText.isEmpty ? FM.tertiary : FM.flash)
                }
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .disabled(!isGenerating && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel(isGenerating ? "Stop generating" : "Send message")
    }

    // MARK: - Generation

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        let userMessage = ChatMessage(role: .user, text: text, timestamp: Date())
        messages.append(userMessage)

        // Start generation
        isGenerating = true
        let assistantMessage = ChatMessage(role: .assistant, text: "", timestamp: Date())
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1

        Task {
            let stream: AsyncStream<GenerationToken>

            if engine.canContinue {
                // Reuse KV cache — only process the new user turn
                stream = engine.generateContinuation(userMessage: text, maxTokens: 500)
            } else {
                // First message — full chat template with system prompt
                let formattedPrompt = buildChatPrompt(userMessage: text)
                stream = engine.generate(prompt: formattedPrompt, maxTokens: 500)
            }

            var gotTokens = false
            for await token in stream {
                // Skip prefill progress tokens (negative tokensGenerated)
                if token.tokensGenerated < 0 { continue }
                gotTokens = true
                let clean = Self.strip(token.text)
                if !clean.isEmpty {
                    messages[assistantIndex].text += clean
                }
            }

            // If continuation returned empty (context full), fall back to full generate
            if !gotTokens && engine.canContinue {
                engine.reset()
                let formattedPrompt = buildChatPrompt(userMessage: text)
                let fallbackStream = engine.generate(prompt: formattedPrompt, maxTokens: 500)
                for await token in fallbackStream {
                    if token.tokensGenerated < 0 { continue }
                    let clean = Self.strip(token.text)
                    if !clean.isEmpty {
                        messages[assistantIndex].text += clean
                    }
                }
            }

            isGenerating = false
            litExperts = []
        }
    }

    /// Strip special tokens that leak through
    private static func strip(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|im_start|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
    }

    /// Format conversation as Qwen chat template
    private func buildChatPrompt(userMessage: String) -> String {
        // Chat template can be disabled in settings (e.g. for smoke test models)
        if !chatTemplateEnabled {
            NSLog("[chat] chat template disabled — sending raw prompt")
            return userMessage
        }

        var prompt = "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n"

        // Include conversation history (skip the empty assistant message we just appended)
        for msg in messages.dropLast() {
            switch msg.role {
            case .user:
                prompt += "<|im_start|>user\n\(msg.text)<|im_end|>\n"
            case .assistant:
                if !msg.text.isEmpty {
                    prompt += "<|im_start|>assistant\n\(msg.text)<|im_end|>\n"
                }
            }
        }

        prompt += "<|im_start|>assistant\n"
        return prompt
    }
}

// MARK: - Message Row

struct MessageRow: View {
    let message: ChatMessage
    @State private var showThinking = false

    /// Split text into visible reply and thinking content
    private var parsedContent: (think: String?, reply: String) {
        let text = message.text
        // Match <think>...</think> blocks
        guard let thinkStart = text.range(of: "<think>"),
              let thinkEnd = text.range(of: "</think>") else {
            // No complete think block — check if still streaming thinking
            if text.hasPrefix("<think>") {
                let thinkBody = String(text.dropFirst("<think>".count))
                return (think: thinkBody, reply: "")
            }
            return (think: nil, reply: text)
        }
        let thinkBody = String(text[thinkStart.upperBound..<thinkEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = String(text[thinkEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (think: thinkBody, reply: reply)
    }

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(FM.sans(14.5))
                    .lineSpacing(2)
                    .foregroundStyle(Color(hex: 0xFFE0AC))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 20, bottomLeadingRadius: 20,
                            bottomTrailingRadius: 7, topTrailingRadius: 20,
                            style: .continuous
                        )
                        .fill(FM.flash.opacity(0.13))
                    )
                    .overlay(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 20, bottomLeadingRadius: 20,
                            bottomTrailingRadius: 7, topTrailingRadius: 20,
                            style: .continuous
                        )
                        .strokeBorder(FM.flash.opacity(0.30), lineWidth: 1)
                    )
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                byline

                if let thinkText = parsedContent.think, !thinkText.isEmpty {
                    thinkingBlock(thinkText)
                }

                if parsedContent.reply.isEmpty && parsedContent.think == nil {
                    StreamingCaret()
                } else {
                    Text(parsedContent.reply)
                        .font(FM.sans(15))
                        .lineSpacing(6)
                        .foregroundStyle(FM.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var byline: some View {
        HStack(spacing: 7) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9))
                .foregroundStyle(FM.flash)
                .frame(width: 19, height: 19)
                .background(FM.flash.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(FM.flash.opacity(0.28), lineWidth: 1)
                )
            FMLabel("flash-moe", color: FM.tertiary)
        }
    }

    private func thinkingBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showThinking.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FM.stream)
                    Text("Thinking")
                        .font(FM.sans(11.5))
                        .foregroundStyle(FM.secondary)
                    Image(systemName: "chevron.down")
                        .font(FM.sans(9, .bold))
                        .foregroundStyle(FM.tertiary)
                        .rotationEffect(.degrees(showThinking ? 180 : 0))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(FM.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(FM.hairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if showThinking {
                Text(text)
                    .font(FM.sans(12.5))
                    .lineSpacing(4)
                    .foregroundStyle(FM.tertiary)
                    .textSelection(.enabled)
                    .padding(.top, 9)
                    .padding(.leading, 2)
            }
        }
    }
}

// MARK: - Streaming caret

struct StreamingCaret: View {
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(FM.flash)
            .frame(width: 8, height: 17)
            .opacity(on ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { on = true }
            }
            .accessibilityLabel("Generating")
    }
}

// MARK: - Model Info Sheet

struct ModelInfoSheet: View {
    let info: ModelInfo?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            FM.ground.ignoresSafeArea()
            if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        sheetHeader(title: (info.name as NSString).lastPathComponent, dismiss: dismiss)

                        infoCard("model", rows: [
                            ("Parameters", info.estimatedParams),
                            ("Routed experts", info.quantLabel),
                            ("Dense / shared", info.denseQuantLabel)
                        ] + (info.isSmokeTest ? [("Mode", "Smoke test (\(info.numExperts))")] : []))

                        infoCard("architecture", rows: [
                            ("Layers", "\(info.numLayers) · \(info.numLinearLayers) linear + \(info.numFullAttnLayers) full"),
                            ("Experts", "\(info.numExperts) total, K=\(info.activeExpertsK)"),
                            ("Hidden dim", "\(info.hiddenDim)"),
                            ("Attention", "\(info.numAttnHeads) Q / \(info.numKVHeads) KV · dim \(info.headDim)"),
                            ("MoE FFN dim", "\(info.moeIntermediate)"),
                            ("Vocab", "\(info.vocabSize)")
                        ])

                        infoCard("storage", rows: [
                            ("Dense weights", String(format: "%.2f GB", info.weightFileMB / 1024)),
                            ("Expert data", String(format: "%.1f GB", info.expertFileMB / 1024)),
                            ("Per expert", String(format: "%.2f MB", info.expertSizeEachMB)),
                            ("Total on disk", String(format: "%.1f GB", info.totalSizeGB))
                        ])

                        infoCard("runtime", rows: [
                            ("GPU buffers", String(format: "%.0f MB", Double(info.metalBufferBytes) / 1_048_576)),
                            ("I/O per token", String(format: "%.2f GB", info.expertSizeEachMB * Double(info.activeExpertsK) * Double(info.numLayers) / 1024))
                        ])
                    }
                    .padding(FM.S.gutter)
                }
                .scrollIndicators(.hidden)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.system(size: 26))
                        .foregroundStyle(FM.tertiary)
                    Text("No model loaded")
                        .font(FM.sans(14))
                        .foregroundStyle(FM.secondary)
                }
            }
        }
        .preferredColorScheme(.dark)
#if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationBackground(FM.ground)
        .presentationDragIndicator(.visible)
#else
        .frame(minWidth: 420, minHeight: 480)
#endif
    }

    private func infoCard(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            FMLabel(title)
            VStack(spacing: 9) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0)
                            .font(FM.sans(13))
                            .foregroundStyle(FM.secondary)
                        Spacer(minLength: 12)
                        Text(row.1)
                            .font(FM.mono(11.5))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(FM.body)
                    }
                }
            }
        }
        .padding(FM.S.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FM.card, in: RoundedRectangle(cornerRadius: FM.R.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FM.R.card, style: .continuous)
                .strokeBorder(FM.hairline, lineWidth: 1)
        )
    }
}

/// Shared title row for the app's sheets.
// Top-level, so nonisolated by default — but it builds SwiftUI views and
// touches main-actor-isolated style values like `.plain`. Both call sites are
// already view bodies, so isolating it to the main actor costs nothing.
@MainActor
func sheetHeader(title: String, dismiss: DismissAction) -> some View {
    HStack(alignment: .center) {
        Text(title)
            .font(FM.titleM)
            .foregroundStyle(FM.ink)
            .lineLimit(2)
        Spacer(minLength: 12)
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
    .padding(.bottom, 2)
}
