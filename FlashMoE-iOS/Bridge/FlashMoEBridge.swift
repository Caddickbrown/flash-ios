/*
 * FlashMoEBridge.swift — Async Swift wrapper for the FlashMoE C engine
 *
 * Provides a Swift-native interface with:
 * - AsyncStream for token-by-token generation
 * - Observable properties for SwiftUI integration
 * - Automatic background thread management
 */

import Foundation
import Observation

// MARK: - Data Types

/// Generation result with streaming tokens
struct GenerationToken {
    let text: String
    let tokenId: Int
    let tokensGenerated: Int
    let tokensPerSecond: Double
}

/// A phase of flashmoe_load(), as reported by the engine's progress callback.
struct LoadPhase: Equatable {
    let stage: String
    let step: Int
    let total: Int

    var fraction: Double { total > 0 ? Double(step) / Double(total) : 0 }
}

/// Average time spent in each pipeline phase of one layer, in milliseconds.
/// Only populated while the engine is built with timing enabled.
struct LayerTiming: Equatable {
    let attention: Double
    let projection: Double
    let expertIO: Double
    let expertCompute: Double
    let total: Double
    let layersSampled: Int

    var isEmpty: Bool { layersSampled == 0 || total <= 0 }

    /// The four phases as fractions of the layer total, for the breakdown bar.
    var shares: [(label: String, value: Double, fraction: Double)] {
        let sum = max(attention + projection + expertIO + expertCompute, 0.0001)
        return [
            ("Attention + delta-net", attention, attention / sum),
            ("Projection + routing", projection, projection / sum),
            ("Expert read from storage", expertIO, expertIO / sum),
            ("Expert compute + combine", expertCompute, expertCompute / sum)
        ]
    }
}

extension LayerTiming {
    /// Nil when the engine has not accumulated any layers yet.
    init?(stats: FlashMoEStats) {
        guard stats.phase_layers_sampled > 0 else { return nil }
        self.init(
            attention: stats.phase_attn_ms,
            projection: stats.phase_proj_ms,
            expertIO: stats.phase_expert_io_ms,
            expertCompute: stats.phase_expert_compute_ms,
            total: stats.phase_total_ms,
            layersSampled: Int(stats.phase_layers_sampled)
        )
    }
}

/// Model information after loading
struct ModelInfo {
    let name: String
    let numLayers: Int
    let numLinearLayers: Int
    let numFullAttnLayers: Int
    let numExperts: Int
    let activeExpertsK: Int
    let hiddenDim: Int
    let vocabSize: Int
    let numAttnHeads: Int
    let numKVHeads: Int
    let headDim: Int
    let moeIntermediate: Int
    let expertQuantBits: Int
    let denseQuantBits: Int
    let denseAvgBits: Float
    let isSmokeTest: Bool
    let weightFileBytes: UInt64
    let expertFileBytes: UInt64
    let metalBufferBytes: UInt64
    let expertSizeEach: UInt64

    var weightFileMB: Double { Double(weightFileBytes) / 1_048_576 }
    var expertFileMB: Double { Double(expertFileBytes) / 1_048_576 }
    var totalSizeMB: Double { weightFileMB + expertFileMB }
    var totalSizeGB: Double { totalSizeMB / 1024 }
    var expertSizeEachMB: Double { Double(expertSizeEach) / 1_048_576 }

    /// Estimated total parameters (rough)
    var estimatedParams: String {
        // Qwen3.5-397B-A17B: 397B total, 17B active
        // Qwen3.5-35B-A3B: 35B total, 3B active
        // Use expert count + dense weights as rough indicator
        if numExperts >= 512 && hiddenDim == 4096 {
            return "397B total / 17B active"
        } else if numExperts >= 128 && hiddenDim == 2048 {
            return "35B total / 3B active"
        } else if numExperts < 512 && hiddenDim == 4096 {
            return "397B (smoke: \(numExperts)/512 experts)"
        }
        return "unknown"
    }

    var quantLabel: String {
        switch expertQuantBits {
        case 2: return "2-bit"
        case 3: return "Q3 (IQ3_XXS/IQ4_XS)"
        case 4: return "4-bit"
        default: return "\(expertQuantBits)-bit"
        }
    }

    var denseQuantLabel: String {
        String(format: "MLX %d-bit (avg %.1f bits/param)", denseQuantBits, denseAvgBits)
    }
}

/// Engine state for UI binding
enum EngineState: Equatable {
    case idle
    case loading
    case ready
    case generating
    case error(String)
}

// MARK: - FlashMoEEngine (Observable)

@Observable
final class FlashMoEEngine: @unchecked Sendable {
    // Observable state for SwiftUI
    private(set) var state: EngineState = .idle
    private(set) var modelInfo: ModelInfo?
    private(set) var tokensPerSecond: Double = 0
    private(set) var tokensGenerated: Int = 0
    private(set) var timeToFirstToken: Double = 0
    private(set) var loadPhase: LoadPhase?
    private(set) var layerTiming: LayerTiming?

    /// Smoke test mode: model has fewer than 512 experts (degraded, skip chat template)
    var isSmoke: Bool { (modelInfo?.numExperts ?? 512) < 512 }

    // Private engine state
    private var context: OpaquePointer?  // FlashMoEContext*
    private let engineQueue = DispatchQueue(label: "com.flashmoe.engine", qos: .userInitiated)
    private var isGenerating = false

    init() {}

    deinit {
        if let ctx = context {
            flashmoe_destroy(ctx)
        }
    }

    // MARK: - Model Loading

    /// Load a model from the given path. Runs on a background thread.
    func loadModel(at path: String, maxContext: Int = 0, thinkBudget: Int = 2048,
                   useTiered: Bool = false, use2bit: Bool = false,
                   cacheIOSplit: Int = 1, verbose: Bool = false,
                   enableTiming: Bool = true) async throws {
        guard state != .loading && state != .generating else {
            throw FlashMoEError.busy
        }

        await MainActor.run {
            state = .loading
            loadPhase = nil
            layerTiming = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            engineQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: FlashMoEError.engineDestroyed)
                    return
                }

                // Create context if needed
                if self.context == nil {
                    self.context = flashmoe_create()
                }
                guard let ctx = self.context else {
                    DispatchQueue.main.async { self.state = .error("Failed to create engine context") }
                    continuation.resume(throwing: FlashMoEError.initFailed)
                    return
                }

                // Configure
                var config = FlashMoEConfig()
                let pathCStr = (path as NSString).utf8String
                config.model_path = pathCStr
                config.max_context = Int32(maxContext)
                config.think_budget = Int32(thinkBudget)
                config.use_tiered = useTiered ? 1 : 0
                config.use_2bit = use2bit ? 1 : 0
                config.cache_io_split = Int32(cacheIOSplit)
                config.verbose = verbose ? 1 : 0
                config.enable_timing = enableTiming ? 1 : 0

                // Load progress. The box is retained for the duration of the
                // (synchronous) load call and released immediately after.
                let progressBox = Unmanaged.passRetained(EngineRef(engine: self)).toOpaque()
                config.progress_user_data = progressBox
                config.progress_cb = { stage, step, total, userData in
                    guard let userData, let stage else { return }
                    let ref = Unmanaged<EngineRef>.fromOpaque(userData).takeUnretainedValue()
                    let phase = LoadPhase(stage: String(cString: stage), step: Int(step), total: Int(total))
                    guard let engine = ref.engine else { return }
                    DispatchQueue.main.async { engine.loadPhase = phase }
                }

                // Load
                let result = flashmoe_load(ctx, &config)
                Unmanaged<EngineRef>.fromOpaque(progressBox).release()
                if result != 0 {
                    let error = String(cString: flashmoe_last_error(ctx))
                    DispatchQueue.main.async { self.state = .error(error) }
                    continuation.resume(throwing: FlashMoEError.loadFailed(error))
                    return
                }

                // Get stats for model info
                var stats = FlashMoEStats()
                flashmoe_get_stats(ctx, &stats)

                let modelName = withUnsafePointer(to: &stats.model_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
                }
                let info = ModelInfo(
                    name: modelName,
                    numLayers: Int(stats.num_layers),
                    numLinearLayers: Int(stats.num_linear_layers),
                    numFullAttnLayers: Int(stats.num_full_attn_layers),
                    numExperts: Int(stats.num_experts),
                    activeExpertsK: Int(stats.active_experts_k),
                    hiddenDim: Int(stats.hidden_dim),
                    vocabSize: Int(stats.vocab_size),
                    numAttnHeads: Int(stats.num_attn_heads),
                    numKVHeads: Int(stats.num_kv_heads),
                    headDim: Int(stats.head_dim),
                    moeIntermediate: Int(stats.moe_intermediate),
                    expertQuantBits: Int(stats.expert_quant_bits),
                    denseQuantBits: Int(stats.dense_quant_bits),
                    denseAvgBits: stats.dense_avg_bits,
                    isSmokeTest: stats.is_smoke_test != 0,
                    weightFileBytes: UInt64(stats.weight_file_bytes),
                    expertFileBytes: UInt64(stats.expert_file_bytes),
                    metalBufferBytes: UInt64(stats.metal_buffer_bytes),
                    expertSizeEach: UInt64(stats.expert_size_each)
                )

                DispatchQueue.main.async {
                    self.modelInfo = info
                    self.loadPhase = nil
                    self.state = .ready
                }
                continuation.resume()
            }
        }
    }

    /// Re-read the engine's per-phase layer timings. Safe to call while
    /// generation is in flight — the accumulator is written by the engine
    /// thread and read here as a snapshot.
    func refreshTiming() {
        guard let ctx = context, state == .ready || state == .generating else { return }
        var stats = FlashMoEStats()
        flashmoe_get_stats(ctx, &stats)
        let timing = LayerTiming(stats: stats)
        if timing != layerTiming { layerTiming = timing }
    }

    /// Unload the current model
    func unloadModel() {
        guard let ctx = context else { return }
        engineQueue.sync {
            flashmoe_unload(ctx)
        }
        modelInfo = nil
        layerTiming = nil
        loadPhase = nil
        state = .idle
    }

    // MARK: - Generation

    /// Generate tokens from a prompt, returning an AsyncStream of tokens
    func generate(prompt: String, maxTokens: Int = 200) -> AsyncStream<GenerationToken> {
        AsyncStream { continuation in
            guard let ctx = context, state == .ready else {
                continuation.finish()
                return
            }

            DispatchQueue.main.async {
                self.state = .generating
                self.tokensGenerated = 0
                self.tokensPerSecond = 0
                self.isGenerating = true
            }

            // The engine context is a bare C pointer, so it is not Sendable.
            // Ownership stays with this object for the lifetime of the stream.
            nonisolated(unsafe) let sendableCtx = ctx

            // Set up cancellation
            continuation.onTermination = { @Sendable _ in
                flashmoe_cancel(sendableCtx)
            }

            engineQueue.async { [weak self] in
                // C callback bridge: userdata points to the Swift continuation
                let userDataPtr = Unmanaged.passRetained(
                    TokenCallbackContext(continuation: continuation, engine: self)
                ).toOpaque()

                let result = flashmoe_generate(
                    sendableCtx,
                    prompt,
                    Int32(maxTokens),
                    { tokenText, tokenId, tokensGenerated, tokensPerSecond, userData -> Int32 in
                        guard let userData else { return 1 }
                        let context = Unmanaged<TokenCallbackContext>.fromOpaque(userData)
                            .takeUnretainedValue()

                        guard let text = tokenText else { return 0 }
                        let token = GenerationToken(
                            text: String(cString: text),
                            tokenId: Int(tokenId),
                            tokensGenerated: Int(tokensGenerated),
                            tokensPerSecond: tokensPerSecond
                        )

                        // Update engine stats on main thread
                        if let engine = context.engine {
                            DispatchQueue.main.async {
                                engine.tokensGenerated = Int(tokensGenerated)
                                engine.tokensPerSecond = tokensPerSecond
                            }
                        }

                        context.continuation.yield(token)
                        return 0
                    },
                    userDataPtr
                )

                // Clean up
                Unmanaged<TokenCallbackContext>.fromOpaque(userDataPtr).release()

                // Get final stats
                var stats = FlashMoEStats()
                flashmoe_get_stats(sendableCtx, &stats)

                let timing = LayerTiming(stats: stats)

                DispatchQueue.main.async {
                    self?.timeToFirstToken = stats.ttft_ms
                    self?.tokensPerSecond = stats.tokens_per_second
                    self?.tokensGenerated = Int(stats.tokens_generated)
                    self?.layerTiming = timing
                    // flashmoe_generate returns -1 on error. Without this the
                    // failure surfaces as a successful but empty response.
                    self?.state = result < 0 ? .error("Generation failed") : .ready
                    self?.isGenerating = false
                }

                continuation.finish()
            }
        }
    }

    /// Generate continuation — reuses KV cache from previous turns.
    /// Returns nil if context is full (caller should reset and use generate instead).
    func generateContinuation(userMessage: String, maxTokens: Int = 200) -> AsyncStream<GenerationToken> {
        AsyncStream { continuation in
            guard let ctx = context, state == .ready else {
                continuation.finish()
                return
            }

            DispatchQueue.main.async {
                self.state = .generating
                self.tokensGenerated = 0
                self.tokensPerSecond = 0
                self.isGenerating = true
            }

            nonisolated(unsafe) let sendableCtx = ctx
            continuation.onTermination = { @Sendable _ in
                flashmoe_cancel(sendableCtx)
            }

            engineQueue.async { [weak self] in
                let userDataPtr = Unmanaged.passRetained(
                    TokenCallbackContext(continuation: continuation, engine: self)
                ).toOpaque()

                let result = flashmoe_generate_continuation(
                    sendableCtx,
                    userMessage,
                    Int32(maxTokens),
                    { tokenText, tokenId, tokensGenerated, tokensPerSecond, userData -> Int32 in
                        guard let userData else { return 1 }
                        let context = Unmanaged<TokenCallbackContext>.fromOpaque(userData)
                            .takeUnretainedValue()

                        guard let text = tokenText else { return 0 }
                        let token = GenerationToken(
                            text: String(cString: text),
                            tokenId: Int(tokenId),
                            tokensGenerated: Int(tokensGenerated),
                            tokensPerSecond: tokensPerSecond
                        )

                        if let engine = context.engine {
                            DispatchQueue.main.async {
                                engine.tokensGenerated = Int(tokensGenerated)
                                engine.tokensPerSecond = tokensPerSecond
                            }
                        }

                        context.continuation.yield(token)
                        return 0
                    },
                    userDataPtr
                )

                Unmanaged<TokenCallbackContext>.fromOpaque(userDataPtr).release()

                // -2 = context full, signal via empty stream (caller handles reset)
                if result == -2 {
                    DispatchQueue.main.async {
                        self?.state = .ready
                        self?.isGenerating = false
                    }
                    continuation.finish()
                    return
                }

                var stats = FlashMoEStats()
                flashmoe_get_stats(sendableCtx, &stats)

                let timing = LayerTiming(stats: stats)

                DispatchQueue.main.async {
                    self?.timeToFirstToken = stats.ttft_ms
                    self?.tokensPerSecond = stats.tokens_per_second
                    self?.tokensGenerated = Int(stats.tokens_generated)
                    self?.layerTiming = timing
                    // -2 (context full) is handled above; -1 is a real failure.
                    self?.state = result < 0 ? .error("Generation failed") : .ready
                    self?.isGenerating = false
                }

                continuation.finish()
            }
        }
    }

    /// Whether the engine has conversation state that can be continued
    var canContinue: Bool {
        guard let ctx = context else { return false }
        return flashmoe_turn_count(ctx) > 0
    }

    /// Cancel an in-progress generation
    func cancel() {
        guard let ctx = context, isGenerating else { return }
        flashmoe_cancel(ctx)
    }

    /// Reset conversation state (KV cache, attention state)
    func reset() {
        guard let ctx = context else { return }
        nonisolated(unsafe) let sendableCtx = ctx
        engineQueue.async {
            flashmoe_reset(sendableCtx)
        }
    }

    // MARK: - Model Validation

    /// Check if a model directory contains a valid Flash-MoE model
    static func validateModel(at path: String) -> Bool {
        return flashmoe_validate_model(path) == 0
    }
}

// MARK: - Helper Types

/// Bridging class to pass the engine through the C load-progress void* callback
private final class EngineRef {
    weak var engine: FlashMoEEngine?

    init(engine: FlashMoEEngine?) {
        self.engine = engine
    }
}

/// Bridging class to pass Swift state through C void* callback
private final class TokenCallbackContext {
    let continuation: AsyncStream<GenerationToken>.Continuation
    weak var engine: FlashMoEEngine?

    init(continuation: AsyncStream<GenerationToken>.Continuation, engine: FlashMoEEngine?) {
        self.continuation = continuation
        self.engine = engine
    }
}

/// Errors from the Flash-MoE engine
enum FlashMoEError: LocalizedError {
    case busy
    case engineDestroyed
    case initFailed
    case loadFailed(String)
    case generateFailed(String)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .busy: return "Engine is busy"
        case .engineDestroyed: return "Engine was destroyed"
        case .initFailed: return "Failed to initialize engine"
        case .loadFailed(let msg): return "Failed to load model: \(msg)"
        case .generateFailed(let msg): return "Generation failed: \(msg)"
        case .notLoaded: return "No model loaded"
        }
    }
}
