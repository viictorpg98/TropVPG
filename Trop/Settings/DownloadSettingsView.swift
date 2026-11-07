//
//  DownloadSettingsView.swift
//  Trop
//

import SwiftUI

struct DownloadSettingsView: View {
    @Environment(\.settingsStore) private var settings
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var storageBytes: Int64 = 0
    @State private var trackCount = 0

    private var storageLabel: String {
        ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file)
    }

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                storageCard
                    .listRowInsets(.init(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            Section {
                SettingsPickerRow("Download Quality", icon: "waveform", selection: $settings.downloadQuality)
                SettingsToggleRow("Wi-Fi Only", icon: "wifi", isOn: $settings.wifiOnlyDownloads)
                SettingsToggleRow("Auto-Download on Like", icon: "heart.fill", isOn: $settings.autoDownloadOnLike)
                SettingsToggleRow("Auto-Download New Episodes", icon: "antenna.radiowaves.left.and.right", isOn: $settings.autoDownloadNewEpisodes)
            } header: {
                Text("Preferences")
            } footer: {
                Text("Auto-download saves liked songs for offline playback. Wi-Fi Only blocks downloads on cellular data.")
            }

            Section {
                SettingsToggleRow("Keep Mix Offline", icon: "icloud.and.arrow.down", isOn: $settings.offlineMixEnabled)
                if settings.offlineMixEnabled {
                    SettingsStepperRow(
                        "Offline Mix Size",
                        icon: "number",
                        value: mixSizeBinding,
                        in: 10...60,
                        step: 10,
                        format: { String(Int($0)) }
                    )
                }
            } header: {
                Text("Offline Mix")
            } footer: {
                Text("Keeps some songs from your mix downloaded (only on Wi-Fi) so Play My Music starts instantly, even without a connection. The set rotates: songs you've heard are replaced by new ones.")
            }

            Section {
                SettingsToggleRow("Free Up Space Automatically", icon: "sparkles", isOn: $settings.smartCleanupEnabled)
            } footer: {
                Text("When storage is low (under 3 GB), removes downloads you haven't played in 3 months. Songs you've liked are never removed. Needs Track Play History turned on.")
            }
        }
        .navigationTitle("Download Settings")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .task { await refreshStats() }
        .onChange(of: downloadManager.persistedDownloadCount) { _, _ in
            Task { await refreshStats() }
        }
    }

    private var mixSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.offlineMixSize) },
            set: { settings.offlineMixSize = Int($0) }
        )
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(storageLabel)
                        .font(.title2.weight(.bold))
                    Text(CountText.offlineTracks(trackCount))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func refreshStats() async {
        storageBytes = await downloadManager.totalStorageBytes()
        trackCount = downloadManager.persistedDownloadCount
    }
}
