/*
 * ModelDownloadRow.swift — Catalog entry card
 *
 * One card per downloadable model, switching between available, downloading,
 * paused, failed and downloaded. Same card shape as the on-device models so
 * the two sections read as one list.
 */

import SwiftUI

struct ModelDownloadRow: View {
    let entry: CatalogEntry
    let downloadManager: DownloadManager
    let isDownloaded: Bool
    /// Opens the full detail screen. The whole card is the target, so the
    /// inline controls below stay available for the common actions.
    var onOpen: (() -> Void)?

    private var quantKind: FMChip.QuantKind {
        let q = entry.quantization.lowercased()
        if q.contains("tiered") { return .tiered }
        if q.contains("2-bit") { return .twoBit }
        return .fourBit
    }

    private var isActiveDownload: Bool {
        downloadManager.activeDownload?.catalogId == entry.id
    }

    private var downloadStatus: DownloadStatus? {
        guard isActiveDownload else { return nil }
        return downloadManager.activeDownload?.status
    }

    private var accent: Color {
        switch downloadStatus {
        case .downloading: FM.stream
        case .paused: FM.flash
        case .failed: FM.danger
        default: FM.hairline
        }
    }

    var body: some View {
        FMCard(
            fill: isDownloaded ? FM.card : FM.sunken,
            stroke: downloadStatus == nil ? Color.white.opacity(0.055) : accent.opacity(0.25)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                header

                switch downloadStatus {
                case .downloading: downloadingView
                case .paused: pausedView
                case .failed: failedView
                case .complete: downloadedView
                case .none: isDownloaded ? AnyView(downloadedView) : AnyView(availableView)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.displayName)
                    .font(FM.sans(14.5, .semibold))
                    .foregroundStyle(FM.body)
                Text(entry.description)
                    .font(FM.sans(11.5))
                    .lineSpacing(2)
                    .foregroundStyle(FM.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            HStack(spacing: 7) {
                FMChip.quant(quantKind)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(FM.faint)
            }
        }
    }

    // MARK: States

    private var availableView: AnyView {
        AnyView(
            HStack {
                Text("\(formatSize(entry.totalSizeBytes)) · \(entry.expertLayers) expert layers")
                    .font(FM.mono(10))
                    .foregroundStyle(FM.faint)
                Spacer()
                Button {
                    downloadManager.startDownload(entry: entry)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: 0xC7CCD4))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.06), in: Circle())
                        .overlay(Circle().strokeBorder(FM.hairlineStrong, lineWidth: 1))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download \(entry.displayName)")
            }
            .padding(.vertical, -5)
        )
    }

    private var downloadingView: some View {
        VStack(alignment: .leading, spacing: 9) {
            FMMeter(value: downloadManager.overallProgress, tint: FM.stream)

            HStack(spacing: 8) {
                Text("\(formatSize(downloadManager.bytesDownloaded)) / \(formatSize(downloadManager.totalBytes))")
                    .font(FM.mono(10.5))
                    .monospacedDigit()
                    .foregroundStyle(FM.stream)

                if downloadManager.downloadSpeed > 0 {
                    Text(formatSpeed(downloadManager.downloadSpeed))
                        .font(FM.mono(10.5))
                        .monospacedDigit()
                        .foregroundStyle(FM.tertiary)
                }

                Spacer(minLength: 4)

                iconAction("pause.fill", "Pause download", FM.flash) { downloadManager.pauseDownload() }
                iconAction("xmark", "Cancel download", FM.danger) { downloadManager.cancelDownload() }
            }

            if let currentFile = downloadManager.activeDownload?.currentFile {
                Text(shortFilename(currentFile))
                    .font(FM.mono(9.5))
                    .foregroundStyle(FM.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var pausedView: some View {
        VStack(alignment: .leading, spacing: 9) {
            FMMeter(value: downloadManager.overallProgress, tint: FM.flash)

            HStack(spacing: 8) {
                Text("Paused · \(formatSize(downloadManager.bytesDownloaded)) / \(formatSize(downloadManager.totalBytes))")
                    .font(FM.mono(10.5))
                    .monospacedDigit()
                    .foregroundStyle(FM.flash)
                Spacer(minLength: 4)
                Button("Resume") { downloadManager.resumeDownload() }
                    .buttonStyle(FMPrimaryButton())
                iconAction("xmark", "Cancel download", FM.danger) { downloadManager.cancelDownload() }
            }
        }
    }

    private var failedView: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let error = downloadManager.activeDownload?.errorMessage ?? downloadManager.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(FM.danger)
                    Text(error)
                        .font(FM.sans(11.5))
                        .lineSpacing(2)
                        .foregroundStyle(FM.danger)
                }
            }

            HStack(spacing: 8) {
                Text("\(formatSize(downloadManager.bytesDownloaded)) downloaded")
                    .font(FM.mono(10.5))
                    .monospacedDigit()
                    .foregroundStyle(FM.tertiary)
                Spacer(minLength: 4)
                Button("Retry") { downloadManager.resumeDownload() }
                    .buttonStyle(FMGhostButton(tint: FM.danger))
                iconAction("xmark", "Cancel download", FM.secondary) { downloadManager.cancelDownload() }
            }
        }
    }

    private var downloadedView: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(FM.stream)
            Text("On device")
                .font(FM.sans(12))
                .foregroundStyle(FM.stream)
            Spacer()
            iconAction("trash", "Delete \(entry.displayName)", FM.danger) {
                downloadManager.deleteModel(catalogId: entry.id)
            }
        }
    }

    private func iconAction(_ system: String, _ label: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.10), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .padding(.vertical, -5)
    }

    // MARK: - Formatting

    private func formatSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.0f MB", mb)
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        let mbps = bytesPerSec / (1024 * 1024)
        return String(format: "%.1f MB/s", mbps)
    }

    private func shortFilename(_ filename: String) -> String {
        (filename as NSString).lastPathComponent
    }
}
