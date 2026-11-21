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
    @State private var voiceBusy = false
    @State private var lastVoiceAttempt = VoiceLog.text
    @AppStorage(CloudVoice.enabledKey) private var cloudVoiceEnabled = false
    @State private var cloudKey = CloudVoice.apiKey
    @State private var cloudStatus = CloudVoice.status
    @State private var cloudVoiceName = CloudVoice.voiceName
    @State private var cloudBusy = false

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
                SettingsNavigationRow("DJ", icon: "mic", value: DJSettings.shared.sessionActive ? "On" : nil) {
                    DJSettingsView()
                }
            } header: {
                Text("Audio")
            }

            Section {
                SettingsToggleRow("Infinite Playback", icon: "infinity", isOn: $settings.autoplaySimilar)
                SettingsToggleRow("Smart Shuffle", icon: "shuffle", isOn: $settings.smartShuffle)
                SettingsToggleRow("Skip Non-Music Parts", icon: "forward.end", isOn: $skipSegments)
                SettingsToggleRow("Enhanced Covers", icon: "photo.on.rectangle", isOn: $settings.richCovers)
                SettingsToggleRow("Mobile Data for Extras", icon: "antenna.radiowaves.left.and.right", isOn: $settings.extrasUseMobileData)
            } header: {
                Text("Player")
            } footer: {
                Text("Infinite Playback keeps similar songs coming when the queue ends. Smart Shuffle puts songs you heard in the last days at the end and keeps two songs by the same artist from playing back to back. With Mobile Data for Extras off, animated covers, video preload and AutoMix on streamed songs only use Wi-Fi.")
            }

            Section {
                Button {
                    voiceBusy = true
                    Task {
                        await VoiceSearch.requestPermissions()
                        await VoiceSearch.run(source: "ajustes")
                        lastVoiceAttempt = VoiceLog.text
                        voiceBusy = false
                    }
                } label: {
                    Label("Try Voice Search", systemImage: "mic")
                }
                .disabled(voiceBusy)
                if !lastVoiceAttempt.isEmpty {
                    Text(lastVoiceAttempt)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy Last Voice Attempt") {
                        UIPasteboard.general.string = lastVoiceAttempt
                    }
                }
            } header: {
                Text("Voice Search")
            } footer: {
                Text("Asks for microphone and speech permission, then asks what you want to listen to and searches for it. The Voice button on the Sonar widget does the same from the Home Screen or CarPlay; what happens in each step is saved in the report.")
            }

            Section {
                Toggle("Cloud Voice", isOn: $cloudVoiceEnabled)
                SecureField("Speechify API Key", text: $cloudKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: cloudKey) {
                        CloudVoice.apiKey = cloudKey
                    }
                if !cloudVoiceName.isEmpty {
                    Text(verbatim: cloudVoiceName)
                        .foregroundStyle(.secondary)
                }
                Button {
                    cloudBusy = true
                    cloudVoiceEnabled = true
                    Task {
                        if let audio = await CloudVoice.audio(for: VoiceSearch.sampleSentence, fetchVoices: true) {
                            _ = await ClipPlayer().play(audio)
                            await CloudVoice.prewarm(VoiceSearch.fixedPhrases)
                        }
                        cloudStatus = CloudVoice.status
                        cloudVoiceName = CloudVoice.voiceName
                        cloudBusy = false
                    }
                } label: {
                    Label("Test Cloud Voice", systemImage: "speaker.wave.2")
                }
                .disabled(cloudBusy || cloudKey.isEmpty)
                Button {
                    cloudBusy = true
                    Task {
                        cloudVoiceEnabled = true
                        _ = await CloudVoice.nextVoice()
                        if let audio = await CloudVoice.audio(for: VoiceSearch.sampleSentence, fetchVoices: true) {
                            _ = await ClipPlayer().play(audio)
                            // La cache es por voz: al cambiar de voz se dejan listas otra vez las frases fijas.
                            await CloudVoice.prewarm(VoiceSearch.fixedPhrases)
                        }
                        cloudStatus = CloudVoice.status
                        cloudVoiceName = CloudVoice.voiceName
                        cloudBusy = false
                    }
                } label: {
                    Label("Next Cloud Voice", systemImage: "forward")
                }
                .disabled(cloudBusy || cloudKey.isEmpty)
                if !cloudStatus.isEmpty {
                    Text(verbatim: cloudStatus)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Cloud Voice")
            } footer: {
                Text("Cloud Voice footer")
            }
        }
        .sonarSettingsList()
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
        .onChange(of: skipSegments) {
            SponsorBlock.save(enabled: skipSegments)
        }
        .onAppear { lastVoiceAttempt = VoiceLog.text }
    }
}
