//
//  AutoMixSettingsView.swift
//  Trop
//
//  Todo lo de AutoMix en su propia pantalla: activarlo, cuando acaba la mezcla, que aprenda de tus valoraciones y lo aprendido.
//

import SwiftUI

struct AutoMixSettingsView: View {
    @Environment(\.settingsStore) private var settings
    @State private var learnedLines: [String] = []

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                SettingsToggleRow("AutoMix", icon: "wand.and.stars", isOn: $settings.autoMixEnabled)
            } footer: {
                Text("Blends one song into the next like a DJ: they overlap, the tempo is matched and the bass is swapped. Streamed songs mix over Wi-Fi unless Mobile Data for Extras is on.")
            }

            Section {
                SettingsPickerRow("Mix Timing", icon: "timer", selection: $settings.autoMixTiming)
            } footer: {
                Text("When the mix ends. Early: right after the last chorus (up to 30 s before the end). Balanced: never earlier than 15 s before the end of the music. Late: at the very end of the song. The intro of the next song is always skipped.")
            }

            Section {
                SettingsToggleRow("AutoMix Learns From Your Ratings", icon: "brain", isOn: $settings.autoMixLearns)
                if learnedLines.isEmpty {
                    Text("No ratings yet. Rate the mixes with the thumbs that appear after each one.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(learnedLines, id: \.self) { line in
                        Text(line)
                    }
                    Button("Reset What AutoMix Learned", role: .destructive) {
                        MixLearning.shared.reset()
                        learnedLines = MixLearning.shared.summary()
                    }
                }
            } header: {
                Text("What AutoMix Learned")
            } footer: {
                Text("Each mix you rate teaches AutoMix which kinds of mixes you like: how long they last and whether the tempo is matched, depending on how close the two songs are. It still tries other styles now and then, and a pair of songs you rated badly is not mixed the same way again.")
            }
        }
        .sonarSettingsList()
        .navigationTitle("AutoMix")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .onAppear { learnedLines = MixLearning.shared.summary() }
    }
}
