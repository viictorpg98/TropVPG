//
//  PlayerSettingsView.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

struct PlayerSettingsView: View {
    @Environment(\.settingsStore) private var settings
    @State private var learnedLines: [String] = []

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                SettingsNavigationRow("Equalizer", icon: "slider.vertical.3") {
                    EqualizerView()
                }
            } header: {
                Text("Equalizer")
            } footer: {
                Text("Adjust the sound with presets or a custom curve.")
            }

            Section {
                SettingsPickerRow("Audio Quality", icon: "waveform", selection: $settings.audioQuality)
                SettingsToggleRow("Audio Normalization", icon: "speaker.wave.2", isOn: $settings.audioNormalization)
                SettingsToggleRow("Gapless Playback", icon: "arrow.right.arrow.left", isOn: $settings.gaplessPlayback)
            } header: {
                Text("Audio")
            }

            Section {
                SettingsToggleRow("Full-Width Artwork", icon: "rectangle.portrait.topthird.inset.filled", isOn: $settings.fullWidthArtwork)
                SettingsToggleRow("Animated Background", icon: "sparkles", isOn: $settings.liveBackground)
                SettingsToggleRow("Waveform Progress Bar", icon: "waveform", isOn: $settings.waveformProgressBar)
            } header: {
                Text("Layout")
            } footer: {
                Text("Shows the cover edge to edge and tints the player with its colors, like Apple Music.")
            }

            Section {
                SettingsToggleRow("Animated Artwork", icon: "play.rectangle.on.rectangle", isOn: $settings.animatedArtworkEnabled)
                SettingsToggleRow("High-Quality Covers", icon: "photo.on.rectangle", isOn: $settings.preferAppleCovers)
                SettingsToggleRow("Animated Artwork on Mobile Data", icon: "antenna.radiowaves.left.and.right", isOn: $settings.animatedArtworkUsesMobileData)
            } header: {
                Text("Animated Artwork")
            } footer: {
                Text("Plays the looping video that goes with a cover (from Apple Music or TIDAL) when the song has one. High-Quality Covers also swaps the cover for the official one when the same song is found there, or for the audio version's cover when a video has one, which helps video clips and remixes. It uses Wi-Fi unless you allow mobile data, and the video turns off in Low Power Mode or with Reduce Motion.")
            }

            Section {
                SettingsToggleRow("Keep Video Ready", icon: "play.rectangle", isOn: $settings.videoPreloadEnabled)
                SettingsToggleRow(
                    "Keep Video Ready on Mobile Data",
                    icon: "antenna.radiowaves.left.and.right",
                    isOn: $settings.videoPreloadUsesMobileData
                )
            } header: {
                Text("Video")
            } footer: {
                Text("Keeps the music video ready behind the cover while the full player is open, so switching to video is instant. It downloads the video even if you never watch it, and uses more battery and data.")
            }

            Section {
                SettingsToggleRow("AutoMix", icon: "wand.and.stars", isOn: $settings.autoMixEnabled)
                SettingsToggleRow("Mix Streamed Songs on Mobile Data", icon: "antenna.radiowaves.left.and.right", isOn: $settings.autoMixUsesMobileData)
                SettingsToggleRow("AutoMix Learns From Your Ratings", icon: "brain", isOn: $settings.autoMixLearns)
            } header: {
                Text("AutoMix")
            } footer: {
                Text("Blends one song into the next like a DJ: they overlap, the tempo is matched and the bass is swapped. Downloaded songs always mix; streamed songs mix over Wi-Fi, or also on mobile data if you turn that on (it downloads each song's audio an extra time). The Playback Report shows what it did.")
            }

            Section {
                SettingsPickerRow("Mix Timing", icon: "timer", selection: $settings.autoMixTiming)
            } footer: {
                Text("When the mix ends. Early: right after the last chorus (up to 30 s before the end). Balanced: never earlier than 15 s before the end of the music. Late: at the very end of the song. The intro of the next song is always skipped.")
            }

            Section {
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

            Section {
                SettingsToggleRow("Autoplay Similar", icon: "infinity", isOn: $settings.autoplaySimilar)
                SettingsToggleRow("Persist Queue", icon: "clock.arrow.circlepath", isOn: $settings.persistQueue)
            } header: {
                Text("Queue")
            } footer: {
                Text("Persist Queue restores your queue, shuffle, and repeat state when the app relaunches.")
            }

            Section {
                SettingsToggleRow("Swipe Artwork to Skip", icon: "hand.draw", isOn: $settings.artworkSwipeNavigation)
            } header: {
                Text("Gestures")
            } footer: {
                Text("Swipe left or right on the artwork in the full player to play the next or previous song.")
            }
        }
        .onAppear { learnedLines = MixLearning.shared.summary() }
        .navigationTitle("Player")
        .navigationBarTitleDisplayMode(.inline)
        .miniPlayerTracksScroll()
    }
}
