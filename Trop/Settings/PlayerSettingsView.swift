//
//  PlayerSettingsView.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

struct PlayerSettingsView: View {
    @Environment(\.settingsStore) private var settings
    @State private var skipSegments = SponsorBlock.isEnabled

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                SettingsNavigationRow("Equalizer", icon: "slider.vertical.3", value: settings.equalizerEnabled ? "On" : "Off") {
                    EqualizerView()
                }
                SettingsPickerRow("Audio Quality", icon: "waveform", selection: $settings.audioQuality)
                SettingsNavigationRow("AutoMix", icon: "wand.and.stars", value: settings.autoMixEnabled ? "On" : "Off") {
                    AutoMixSettingsView()
                }
            } header: {
                Text("Audio")
            }

            Section {
                SettingsToggleRow("Infinite Playback", icon: "infinity", isOn: $settings.autoplaySimilar)
                SettingsToggleRow("Skip Non-Music Parts", icon: "forward.end", isOn: $skipSegments)
                SettingsToggleRow("Enhanced Covers", icon: "photo.on.rectangle", isOn: $settings.richCovers)
                SettingsToggleRow("Mobile Data for Extras", icon: "antenna.radiowaves.left.and.right", isOn: $settings.extrasUseMobileData)
            } header: {
                Text("Player")
            } footer: {
                Text("Infinite Playback keeps similar songs coming when the queue ends. With Mobile Data for Extras off, animated covers, video preload and AutoMix on streamed songs only use Wi-Fi.")
            }
        }
        .sonarSettingsList()
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .onChange(of: skipSegments) {
            SponsorBlock.save(enabled: skipSegments)
        }
    }
}
