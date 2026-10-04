/*
 * ModelDetailView.swift — Catalog entry detail and download
 *
 * Opened from a card in the library. Shows what the model is, the live
 * download state, and the file manifest so a stalled 300 MB expert layer is
 * visible rather than hidden behind one aggregate bar.
 */

import SwiftUI

struct ModelDetailView: View {
    let entry: CatalogEntry
    let downloadManager: DownloadManager
    let isDownloaded: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var wifiOnly: Bool = DownloadManager.shared.wifiOnly

    private var isActive: Bool {
        downloadManager.activeDownload?.catalogId == entry.id
    }

    private var status: DownloadStatus? {
        isActive ? downloadManager.activeDownload?.status : nil
    }

    private var quantKind: FMChip.QuantKind {
        let q = entry.quantization.lowercased()
        if q.contains("tiered") { return .tiered }
        if q.contains("2-bit") { return .twoBit }
        return .fourBit
    }

    var body: some View {
        ZStack {
            FM.ground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar

                    Text(entry.displayName)
                        .font(FM.sans(25, .bold))
                        .kerning(-0.7)
                        .foregroundStyle(FM.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(entry.description)
                        .font(FM.sans(13.5))
                        .lineSpacing(4)
                        .foregroundStyle(FM.secondary)
                        .padding(.top, 9)

                    HStack(spacing: 6) {
                        FMChip.quant(quantKind)
                        FMChip(text: formatSize(entry.totalSizeBytes))
                        FMChip(text: "\(entry.expertLayers) layers")
                    }
                    .padding(.top, 14)

                    stateCard
                        .padding(.top, 22)

                    FMLabel("files")
                        .padding(.top, 22)
                        .padding(.leading, 3)

                    fileList
                        .padding(.top, 10)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
#if os(iOS)
        .presentationDetents([.large])
        .presentationBackground(FM.ground)
        .presentationDragIndicator(.hidden)
#else
        .frame(minWidth: 460, minHeight: 620)
#endif
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
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
            .accessibilityLabel("Back")

            Spacer()

            if status != nil {
                Button("Cancel") { downloadManager.cancelDownload() }
                    .buttonStyle(FMGhostButton(tint: FM.danger))
            } else if isDownloaded {
                Button("Delete") { downloadManager.deleteModel(catalogId: entry.id) }
                    .buttonStyle(FMGhostButton(tint: FM.danger))
            }
        }
        .padding(.leading, -4)
        .padding(.bottom, 14)
    }

    // MARK: State card

    @ViewBuilder
    private var stateCard: some View {
        switch status {
        case .downloading, .paused:
            progressCard(paused: status == .paused)
        case .failed:
            failedCard
        case .complete:
            readyCard
        case .none:
            isDownloaded ? AnyView(readyCard) : AnyView(startCard)
        }
    }

    private var accent: Color { status == .paused ? FM.flash : FM.stream }

    private func progressCard(paused: Bool) -> some View {
        FMCard(stroke: accent.opacity(0.22)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.2f", Double(downloadManager.bytesDownloaded) / 1_073_741_824))
                        .font(FM.mono(22, .semibold))
                        .monospacedDigit()
                        .kerning(-0.8)
                        .foregroundStyle(accent)
                    Text("/ \(formatSize(downloadManager.totalBytes))")
                        .font(FM.mono(11))
                        .foregroundStyle(FM.tertiary)
                    Spacer()
                    if downloadManager.downloadSpeed > 0 && !paused {
                        Text(formatSpeed(downloadManager.downloadSpeed))
                            .font(FM.mono(11))
                            .monospacedDigit()
                            .foregroundStyle(FM.secondary)
                    }
                }

                FMMeter(value: downloadManager.overallProgress, tint: accent)

                HStack {
                    Text(downloadManager.activeDownload?.currentFile.map(shortFilename) ?? "—")
                        .font(FM.mono(10))
                        .foregroundStyle(FM.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 10)
                    Text(remainingText(paused: paused))
                        .font(FM.mono(10))
                        .monospacedDigit()
                        .foregroundStyle(FM.secondary)
                }

                HStack(spacing: 8) {
                    if paused {
                        Button {
                            downloadManager.resumeDownload()
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(FMPrimaryButton(expands: true))
                    } else {
                        Button {
                            downloadManager.pauseDownload()
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .buttonStyle(FMGhostButton(expands: true))
                    }
                }

                wifiToggle
            }
        }
    }

    private var startCard: some View {
        FMCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Not downloaded")
                            .font(FM.sans(14, .semibold))
                            .foregroundStyle(FM.ink)
                        Text("\(entry.files.count) files · \(formatSize(entry.totalSizeBytes))")
                            .font(FM.mono(10.5))
                            .foregroundStyle(FM.tertiary)
                    }
                    Spacer()
                }

                Button {
                    downloadManager.startDownload(entry: entry)
                } label: {
                    Label("Download", systemImage: "arrow.down")
                }
                .buttonStyle(FMPrimaryButton(expands: true))

                wifiToggle
            }
        }
    }

    private var readyCard: some View {
        FMCard(stroke: FM.stream.opacity(0.22)) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(FM.stream)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On device")
                        .font(FM.sans(14, .semibold))
                        .foregroundStyle(FM.ink)
                    Text("Load it from the library to start a chat.")
                        .font(FM.sans(11.5))
                        .foregroundStyle(FM.tertiary)
                }
                Spacer()
            }
        }
    }

    private var failedCard: some View {
        FMCard(fill: FM.danger.opacity(0.08), stroke: FM.danger.opacity(0.25)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(FM.danger)
                    Text(downloadManager.activeDownload?.errorMessage
                         ?? downloadManager.error
                         ?? "Download failed")
                        .font(FM.sans(12.5))
                        .lineSpacing(2)
                        .foregroundStyle(FM.danger)
                }

                Text("\(formatSize(downloadManager.bytesDownloaded)) downloaded so far — resuming picks up from there.")
                    .font(FM.sans(11.5))
                    .foregroundStyle(FM.secondary)

                Button("Retry") { downloadManager.resumeDownload() }
                    .buttonStyle(FMPrimaryButton(expands: true))
            }
        }
    }

    private var wifiToggle: some View {
        HStack {
            Image(systemName: "wifi")
                .font(.system(size: 12))
                .foregroundStyle(FM.secondary)
            Text("Wi-Fi only")
                .font(FM.sans(12.5))
                .foregroundStyle(FM.secondary)
            Spacer()
            Toggle("", isOn: $wifiOnly)
                .labelsHidden()
                .tint(FM.stream)
                .onChange(of: wifiOnly) { _, on in
                    downloadManager.wifiOnly = on
                }
        }
        .padding(.top, 2)
    }

    // MARK: File list

    private var fileList: some View {
        VStack(spacing: 0) {
            ForEach(Array(entry.files.enumerated()), id: \.element.id) { index, file in
                let state = fileState(file)
                HStack(spacing: 10) {
                    fileMarker(state)
                    Text(shortFilename(file.filename))
                        .font(FM.mono(11.5))
                        .foregroundStyle(state == .current ? FM.ink : (state == .done ? FM.secondary : FM.faint))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(formatSize(file.sizeBytes))
                        .font(FM.mono(10.5))
                        .monospacedDigit()
                        .foregroundStyle(FM.faint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                if index < entry.files.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.045))
                        .frame(height: 1)
                        .padding(.leading, 14)
                }
            }
        }
        .background(FM.sunken, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: 1)
        )
    }

    private enum FileState { case done, current, pending }

    private func fileState(_ file: RepoFile) -> FileState {
        if isDownloaded { return .done }
        if downloadManager.isFileComplete(file.filename) { return .done }
        if downloadManager.activeDownload?.currentFile == file.filename { return .current }
        return .pending
    }

    @ViewBuilder
    private func fileMarker(_ state: FileState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(FM.stream)
                .frame(width: 14, height: 14)
                .background(FM.stream.opacity(0.16), in: Circle())
                .overlay(Circle().strokeBorder(FM.stream.opacity(0.45), lineWidth: 1))
        case .current:
            FMPulse(color: FM.flash, size: 14)
        case .pending:
            Circle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: Formatting

    private func remainingText(paused: Bool) -> String {
        if paused { return "PAUSED" }
        let remaining = downloadManager.totalBytes > downloadManager.bytesDownloaded
            ? downloadManager.totalBytes - downloadManager.bytesDownloaded
            : 0
        guard downloadManager.downloadSpeed > 1 else { return "—" }
        let seconds = Double(remaining) / downloadManager.downloadSpeed
        if seconds < 90 { return String(format: "%.0f SEC LEFT", seconds) }
        if seconds < 5400 { return String(format: "%.0f MIN LEFT", seconds / 60) }
        return String(format: "%.1f HR LEFT", seconds / 3600)
    }

    private func formatSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024.0)
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
    }

    private func shortFilename(_ filename: String) -> String {
        (filename as NSString).lastPathComponent
    }
}
