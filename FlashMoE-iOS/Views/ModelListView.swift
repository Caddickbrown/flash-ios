/*
 * ModelListView.swift — Model library
 *
 * Custom scroll surface rather than a grouped List: device storage at the top,
 * on-device models as cards (the loaded one ringed in amber), then the
 * downloadable catalog.
 */

import SwiftUI

// MARK: - Local Model Entry

struct LocalModel: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let sizeBytes: UInt64
    let hasTiered: Bool
    let has4bit: Bool
    let has2bit: Bool

    var sizeMB: Double { Double(sizeBytes) / 1_048_576 }
    var sizeGB: Double { sizeMB / 1024 }

    var quant: FMChip.QuantKind? {
        if hasTiered { return .tiered }
        if has4bit { return .fourBit }
        if has2bit { return .twoBit }
        return nil
    }
}

// MARK: - Model List View

struct ModelListView: View {
    @Environment(FlashMoEEngine.self) private var engine
    @State private var localModels: [LocalModel] = []
    @State private var isScanning = true
    @State private var selectedModel: LocalModel?
    @State private var showSettings = false
    @State private var detailEntry: CatalogEntry?
    @AppStorage("cacheIOSplit") private var cacheIOSplit: Int = 1
    private let downloadManager = DownloadManager.shared

    private var isLoading: Bool { engine.state == .loading }

    var body: some View {
        FMScreen {
            if isLoading {
                LoadingView(modelName: selectedModel?.name ?? "model", phase: engine.loadPhase) {
                    engine.unloadModel()
                    selectedModel = nil
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                library
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isLoading)
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(item: $detailEntry) { entry in
            let hasActiveDownload = downloadManager.activeDownload?.catalogId == entry.id
                && downloadManager.activeDownload?.status != .complete
            ModelDetailView(
                entry: entry,
                downloadManager: downloadManager,
                isDownloaded: !hasActiveDownload && downloadManager.isModelDownloaded(entry.id)
            )
        }
        .onAppear { scanForModels() }
        .onChange(of: downloadManager.activeDownload?.status) { _, newStatus in
            if newStatus == .complete { scanForModels() }
        }
    }

    // MARK: Library

    private var library: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    StorageCard(models: localModels)

                    if let message = errorMessage {
                        errorCard(message)
                    }

                    FMLabel("on device")
                        .padding(.leading, 3)

                    if isScanning {
                        scanningCard
                    } else if localModels.isEmpty {
                        emptyCard
                    } else {
                        ForEach(localModels) { model in
                            ModelCard(
                                model: model,
                                isLoaded: engine.modelInfo?.name == model.path
                            ) {
                                loadModel(model)
                            }
                        }
                    }

                    FMLabel("available")
                        .padding(.top, 4)
                        .padding(.leading, 3)

                    ForEach(ModelCatalog.models) { entry in
                        let hasActiveDownload = downloadManager.activeDownload?.catalogId == entry.id
                            && downloadManager.activeDownload?.status != .complete
                        ModelDownloadRow(
                            entry: entry,
                            downloadManager: downloadManager,
                            isDownloaded: !hasActiveDownload && downloadManager.isModelDownloaded(entry.id),
                            onOpen: { detailEntry = entry }
                        )
                    }
                }
                .padding(.horizontal, FM.S.gutter)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .refreshable { scanForModels() }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(FM.flash)
                    Text("Models")
                        .font(FM.titleL)
                        .kerning(-0.7)
                        .foregroundStyle(FM.ink)
                }
                Text("Mixture-of-experts, streamed from storage.")
                    .font(FM.sans(13))
                    .foregroundStyle(FM.secondary)
            }
            Spacer(minLength: 8)
            FMIconButton(system: "slider.horizontal.3", label: "Settings") { showSettings = true }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var errorMessage: String? {
        if case .error(let msg) = engine.state { return msg }
        if let err = downloadManager.error, downloadManager.activeDownload == nil { return err }
        return nil
    }

    private func errorCard(_ message: String) -> some View {
        FMCard(fill: FM.danger.opacity(0.08), stroke: FM.danger.opacity(0.25)) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(FM.danger)
                Text(message)
                    .font(FM.sans(12.5))
                    .lineSpacing(2)
                    .foregroundStyle(FM.danger)
            }
        }
    }

    private var scanningCard: some View {
        FMCard {
            HStack(spacing: 10) {
                FMPulse(color: FM.stream)
                Text("Scanning for models…")
                    .font(FM.sans(13.5))
                    .foregroundStyle(FM.secondary)
            }
        }
    }

    private var emptyCard: some View {
        FMCard(fill: FM.sunken, stroke: Color.white.opacity(0.055)) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Nothing on device yet")
                    .font(FM.sans(14.5, .semibold))
                    .foregroundStyle(FM.body)
                Text("Download one below, or drop a packed model into the Flash-MoE folder in Files.")
                    .font(FM.sans(12.5))
                    .lineSpacing(2)
                    .foregroundStyle(FM.tertiary)
            }
        }
    }

    // MARK: Actions

    private func scanForModels() {
        isScanning = true
        localModels = []

        Task {
            let models = await ModelScanner.scanLocalModels()
            await MainActor.run {
                localModels = models
                isScanning = false
            }
        }
    }

    private func loadModel(_ model: LocalModel) {
        guard engine.state != .loading && engine.state != .generating else { return }
        selectedModel = model

        Task {
            do {
                try await engine.loadModel(
                    at: model.path,
                    maxContext: 4096,
                    useTiered: model.hasTiered,
                    use2bit: model.has2bit && !model.hasTiered && !model.has4bit,
                    cacheIOSplit: cacheIOSplit,
                    verbose: true
                )
            } catch {
                // Error state is set by the engine
            }
        }
    }
}

// MARK: - Storage Card

struct StorageCard: View {
    let models: [LocalModel]

    private var usedBytes: UInt64 { models.reduce(0) { $0 + $1.sizeBytes } }

    private var freeBytes: UInt64 {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return UInt64(max(capacity, 0))
    }

    var body: some View {
        FMCard(radius: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    FMLabel("device storage")
                    Spacer()
                    Text(String(format: "%.1f GB used · %.0f GB free", gb(usedBytes), gb(freeBytes)))
                        .font(FM.mono(11))
                        .monospacedDigit()
                        .foregroundStyle(Color(hex: 0xC7CCD4))
                }

                FMMeter(value: fraction, tint: FM.flash, height: 7)

                HStack(spacing: 14) {
                    legend(FM.flash, "Models \(String(format: "%.1f GB", gb(usedBytes)))")
                    legend(Color.white.opacity(0.18), "Free \(String(format: "%.0f GB", gb(freeBytes)))")
                }
            }
        }
    }

    private var fraction: Double {
        let total = Double(usedBytes) + Double(freeBytes)
        guard total > 0 else { return 0 }
        return Double(usedBytes) / total
    }

    private func gb(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(FM.sans(10.5))
                .foregroundStyle(FM.secondary)
        }
    }
}

// MARK: - Model Card

struct ModelCard: View {
    let model: LocalModel
    let isLoaded: Bool
    let onLoad: () -> Void

    var body: some View {
        FMCard(
            fill: isLoaded ? FM.raised : FM.card,
            stroke: isLoaded ? FM.flash.opacity(0.38) : FM.hairline
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(model.name)
                            .font(FM.sans(16, .semibold))
                            .kerning(-0.2)
                            .foregroundStyle(FM.ink)
                            .lineLimit(2)

                        HStack(spacing: 6) {
                            if let quant = model.quant { FMChip.quant(quant) }
                            FMChip(text: String(format: "%.1f gb", model.sizeGB))
                        }
                    }

                    Spacer(minLength: 6)

                    if isLoaded {
                        HStack(spacing: 5) {
                            FMPulse(color: FM.flash, size: 5)
                            FMLabel("loaded", color: FM.flash)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(FM.flash.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    } else {
                        Button("Load", action: onLoad)
                            .buttonStyle(FMPrimaryButton())
                    }
                }

                if isLoaded {
                    Divider()
                        .overlay(FM.hairline)
                        .padding(.vertical, 12)

                    HStack {
                        Text("Ready for chat")
                            .font(FM.mono(10))
                            .foregroundStyle(FM.secondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Text("Open chat")
                                .font(FM.sans(13.5, .semibold))
                            Image(systemName: "chevron.right")
                                .font(FM.sans(11, .bold))
                        }
                        .foregroundStyle(FM.flash)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isLoaded { onLoad() } }
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cacheIOSplit") private var cacheIOSplit: Int = 1
    @AppStorage("chatTemplateEnabled") private var chatTemplateEnabled: Bool = true

    var body: some View {
        ZStack {
            FM.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sheetHeader(title: "Settings", dismiss: dismiss)

                    FMCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Chat template")
                                        .font(FM.sans(14, .semibold))
                                        .foregroundStyle(FM.ink)
                                    Text("Wrap prompts in the Qwen format. Turn off for smoke-test models or raw completion.")
                                        .font(FM.sans(11.5))
                                        .lineSpacing(2)
                                        .foregroundStyle(FM.tertiary)
                                }
                                Spacer(minLength: 10)
                                Toggle("", isOn: $chatTemplateEnabled)
                                    .labelsHidden()
                                    .tint(FM.flash)
                            }
                        }
                    }

                    FMCard {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Expert I/O fanout")
                                    .font(FM.sans(14, .semibold))
                                    .foregroundStyle(FM.ink)
                                Text("Splits each expert read into page-aligned chunks issued in parallel. Applies on the next load.")
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

                    Text("Models live in the app's Documents folder and are excluded from backup so iOS will not purge them.")
                        .font(FM.sans(11.5))
                        .lineSpacing(3)
                        .foregroundStyle(FM.faint)
                        .padding(.horizontal, 3)
                }
                .padding(FM.S.gutter)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
#if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationBackground(FM.ground)
        .presentationDragIndicator(.visible)
#else
        .frame(minWidth: 420, minHeight: 420)
#endif
    }
}

// MARK: - Model Scanner

enum ModelScanner {
    /// Scan common locations for Flash-MoE model directories
    static func scanLocalModels() async -> [LocalModel] {
        var models: [LocalModel] = []
        let fm = FileManager.default

        // Scan app Documents directory
        if let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            await scanDirectory(docsDir.path, into: &models)
        }

        // Note: App Groups container removed — no entitlement configured.
        // Models are discovered from the Documents directory (accessible via Files.app).

        return models.sorted { $0.name < $1.name }
    }

    private static func scanDirectory(_ path: String, into models: inout [LocalModel]) async {
        let fm = FileManager.default

        print("[model-scan] Scanning: \(path)")
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
            print("[model-scan] ERROR: cannot list \(path)")
            return
        }
        print("[model-scan] Found \(entries.count) entries: \(entries.sorted().joined(separator: ", "))")

        for entry in entries {
            let fullPath = (path as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let valid = FlashMoEEngine.validateModel(at: fullPath)
            if !valid {
                // Debug: show why validation failed
                let hasConfig = fm.fileExists(atPath: (fullPath as NSString).appendingPathComponent("config.json"))
                let hasWeights = fm.fileExists(atPath: (fullPath as NSString).appendingPathComponent("model_weights.bin"))
                let hasManifest = fm.fileExists(atPath: (fullPath as NSString).appendingPathComponent("model_weights.json"))
                let hasExperts4 = fm.fileExists(atPath: (fullPath as NSString).appendingPathComponent("packed_experts/layer_00.bin"))
                let hasExpertsT = fm.fileExists(atPath: (fullPath as NSString).appendingPathComponent("packed_experts_tiered/layer_00.bin"))
                let hasExperts2 = fm.fileExists(atPath: (fullPath as NSString).appendingPathComponent("packed_experts_2bit/layer_00.bin"))
                print("[model-scan] SKIP '\(entry)': config=\(hasConfig) weights=\(hasWeights) manifest=\(hasManifest) experts(4bit=\(hasExperts4) tiered=\(hasExpertsT) 2bit=\(hasExperts2))")
                continue
            }

            // Protect model files from iOS storage optimization / purging
            excludeFromBackup(URL(fileURLWithPath: fullPath))
            let size = directorySize(at: fullPath)
            let hasTiered = fm.fileExists(atPath: (fullPath as NSString).appendingPathComponent("packed_experts_tiered/layer_00.bin"))
            let has4bit = fm.fileExists(atPath: (fullPath as NSString).appendingPathComponent("packed_experts/layer_00.bin"))
            let has2bit = fm.fileExists(atPath: (fullPath as NSString).appendingPathComponent("packed_experts_2bit/layer_00.bin"))

            print("[model-scan] OK '\(entry)': size=\(size / (1024*1024))MB tiered=\(hasTiered) 4bit=\(has4bit) 2bit=\(has2bit)")
            models.append(LocalModel(
                name: entry,
                path: fullPath,
                sizeBytes: size,
                hasTiered: hasTiered,
                has4bit: has4bit,
                has2bit: has2bit
            ))
        }
        print("[model-scan] Total valid models: \(models.count)")
    }

    private static func directorySize(at path: String) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: UInt64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? UInt64 {
                total += size
            }
        }
        return total
    }

    /// Mark a directory (and its contents) as excluded from iCloud backup and
    /// iOS storage optimization, preventing the system from purging model files.
    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)

        // Also mark all files inside
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        while let fileURL = enumerator.nextObject() as? URL {
            var fileURL = fileURL
            try? fileURL.setResourceValues(values)
        }
    }
}
